-- The lock on the store's own objects. Runs LAST on every boot. See DECISIONS 37.
--
-- What this is for: the tools are security-definer functions that take the agent's name as
-- a parameter and trust the gateway to have filled it in from the key. That trust is only
-- sound while the gateway is the only way to call them. Postgres gives PUBLIC execute on
-- every new function, and Supabase's defaults grant anon and authenticated on top -- so the
-- same functions were callable through PostgREST at /rest/v1/rpc by anyone holding the
-- anon key, with any agent name they liked, and the unprotected tables were readable
-- outright. The gateway now refuses that key everywhere (kong.yml), and this file makes the
-- database refuse it too, so the next mistake in a route is a 4xx and not a master key.
--
-- Extension functions (vector, pg_trgm) are left alone: they are arithmetic, they are owned
-- by supabase_admin, and revoking PUBLIC from them would only cost postgres its own access.
-- Row-security policies that name anon (skill_library) become inert; they are not removed,
-- because a policy without a grant grants nothing.
--
-- Idempotent: every statement can run against a store that is already locked.

do $$
declare r record; role_ text; sch text;
begin
  -- 1. Nothing the store defines is executable by PUBLIC, anon or authenticated.
  --    service_role is what the functions container and the caretaker's raw-SQL door use.
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      left join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
     where n.nspname in ('public', 'platform') and d.objid is null
  loop
    execute format('revoke all on routine %s from public, anon, authenticated', r.sig);
    execute format('grant execute on routine %s to service_role', r.sig);
  end loop;

  -- 2. No table, view or sequence of the store is reachable by anon or authenticated.
  --    (PUBLIC never had these; Supabase's defaults gave them to the two roles by name.)
  foreach sch in array array['public', 'platform'] loop
    execute format('revoke all on all tables in schema %I from anon, authenticated', sch);
    execute format('revoke all on all sequences in schema %I from anon, authenticated', sch);
  end loop;
  revoke usage on schema platform from anon, authenticated;

  -- 3. And nothing created later gets them back. Default privileges are per creating role:
  --    postgres owns the store (the seed connects as postgres); supabase_admin is covered
  --    for an install that was seeded by hand. Altering another role's defaults needs
  --    membership or superuser; where the seed has neither, that role's row is skipped and
  --    said so -- the objects it owns were still locked by 1 and 2 above.
  --
  --    Two different mechanisms, and the difference matters. Supabase granted anon and
  --    authenticated PER SCHEMA, so a per-schema revoke undoes it. PUBLIC's execute on new
  --    functions is Postgres's built-in default, and the manual is explicit that a per-schema
  --    revoke cannot touch it ("you cannot revoke privileges per-schema if they are granted
  --    globally"): it has to be revoked in the role's GLOBAL defaults. That is what caught
  --    platform.similar, which the embedder recreates at run time when the dimension changes.
  foreach role_ in array array['postgres', 'supabase_admin'] loop
    begin
      execute format('alter default privileges for role %I revoke execute on routines from public', role_);
      foreach sch in array array['public', 'platform'] loop
        execute format('alter default privileges for role %I in schema %I revoke execute on routines from public, anon, authenticated', role_, sch);
        execute format('alter default privileges for role %I in schema %I revoke all on tables from anon, authenticated', role_, sch);
        execute format('alter default privileges for role %I in schema %I revoke all on sequences from anon, authenticated', role_, sch);
      end loop;
    exception when insufficient_privilege then
      raise notice 'platform_lock: cannot alter default privileges for role %, skipped (objects it owns are locked regardless)', role_;
    end;
  end loop;

  -- 4. With PUBLIC gone from the defaults, whatever postgres creates from now on -- including
  --    an extension it installs -- is executable only by its owner unless granted. The
  --    administrator's role is granted everything in the store's two schemas, extension
  --    functions included, so raw SQL through /mcp keeps its operators.
  foreach sch in array array['public', 'platform'] loop
    execute format('grant execute on all routines in schema %I to service_role', sch);
  end loop;
end $$;

-- The store can see whether this held. Read by platform.health() as the check 'the third key'.
create or replace view platform.v_open_to_anon as
select 'routine'::text as kind, n.nspname || '.' || p.proname as name
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  left join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
 where n.nspname in ('public', 'platform') and d.objid is null
   and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
union all
select 'table', n.nspname || '.' || c.relname
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname in ('public', 'platform') and c.relkind in ('r', 'v', 'm', 'p')
   and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select'));
comment on view platform.v_open_to_anon is 'Objects of the store that the anon or authenticated role could reach. Must be empty: those roles belong to keys that are not agents. If a row appears, a grant somewhere named them again.';
grant select on platform.v_open_to_anon to service_role;
