-- Conventions for data shared between Hermes agents.
-- Run AFTER demo/skill_library.sql -- the skill at the bottom is inserted there.
--
-- The model: anyone may read and write public data, but every row shows who created it
-- and who changed it last. Private data (visibility = 'private') is the owner's alone.
--
-- Private is enforced by the house tools, which take the caller from the gateway's
-- verified header and filter on it. It is NOT enforced by row security: every agent
-- arrives as one database role, and that role carries rolbypassrls, so policies never
-- apply to it. The policies at the bottom of this file are written for the day agents
-- connect as `authenticated` with a per-agent token -- they obey policies for real.
-- Until then they are inert, and saying so is better than implying protection.

-- 1) Timestamps come from the database, not from the agent.
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- 2) The shared template. Call it for every new table and it arrives with the standard
--    columns, row security, the timestamp trigger and comments in one step:
--      select public.create_shared_table('notes', 'Free-form notes per agent');
--    Then add your own columns with ALTER TABLE.
create or replace function public.create_shared_table(table_name text, description text default null)
returns void language plpgsql as $$
begin
  execute format($f$
    create table if not exists public.%1$I (
      id          uuid primary key default gen_random_uuid(),
      owner       text not null,
      visibility  text not null default 'public' check (visibility in ('public','private')),
      created_by  text not null,
      updated_by  text not null,
      created_at  timestamptz not null default now(),
      updated_at  timestamptz not null default now()
    )$f$, table_name);
  execute format('alter table public.%I enable row level security', table_name);
  execute format('drop trigger if exists set_updated_at on public.%I', table_name);
  execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()', table_name);
  execute format('create index if not exists %I on public.%I (owner, visibility)', table_name || '_owner_visibility_idx', table_name);
  if description is not null then
    execute format('comment on table public.%I is %L', table_name, description);
  end if;
  execute format('comment on column public.%I.owner is %L', table_name, 'The agent identifier, agent_NN. Set by the agent on insert.');
  execute format('comment on column public.%I.visibility is %L', table_name, 'public = everyone may read and write, private = the owner only.');
  execute format('comment on column public.%I.created_by is %L', table_name, 'Who created the row. Set by the agent.');
  execute format('comment on column public.%I.updated_by is %L', table_name, 'Who last changed the row. Set by the agent on every update.');
end $$;

-- 3) One example built on the template: free-form notes.
select public.create_shared_table('notes', 'Free-form notes. Public ones are shared by every agent, private ones belong to the owner alone.');
alter table public.notes
  add column if not exists title text not null,
  add column if not exists content text not null default '',
  add column if not exists tags text[] not null default '{}';
comment on column public.notes.title is 'Short heading.';
comment on column public.notes.content is 'Body text, markdown allowed.';
comment on column public.notes.tags is 'Free tags, for searching.';

-- Soft deletion. These three columns are what make skillhub_retire work, and until
-- 2026-09-14 they existed only in the live database -- added by hand and committed to no
-- file. A fresh deploy would have produced a store where retiring anything fails, which is
-- one of the ten criteria this system is measured against. Found by seeding an empty
-- database and diffing its columns against production. Nothing prevents that kind of drift
-- except applying the files as the only way a schema changes.
alter table public.notes
  add column if not exists retired_at     timestamptz,
  add column if not exists retired_by     text,
  add column if not exists retired_reason text;
comment on column public.notes.retired_at is 'When it was retired. Retired rows leave search and stay readable -- nothing here is ever deleted, because the change log keeps no contents.';
comment on column public.notes.retired_by is 'Who retired it. Comes from the gateway, not from the caller.';
comment on column public.notes.retired_reason is 'Why it stopped applying. Required: whoever finds it next needs to know.';


-- 3b) Who is who: identifier -> person. Public, every agent may read it.
create table if not exists public.agents (
  -- agent_NN for a person's agent, and service_role for the caretaker. The caretaker is
  -- listed here on purpose: skillhub_overview tells every agent who else is in the store, and
  -- an agent that sees "service_role -- Caretaker (system)" understands that the bulk loads
  -- and the tidying are not a colleague's work. Leaving it out would make a machine look like
  -- one of the eight.
  id          text primary key check (id ~ '^agent_[0-9]{2}$' or id = 'service_role'),
  name        text,
  role        text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table public.agents enable row level security;
comment on table public.agents is
  'Maps an agent identifier to a person. agent_NN is bound to MCP key slot NN in volumes/api/kong.yml, not here -- no key material is ever stored in the database, and this table is only the last step, agent -> human. Filled in by an admin, directly or through Studio.
   It deliberately lacks the convention columns (owner, visibility, created_by, updated_by), and that omission is the only thing keeping agents out of it: skillhub_add_rows refuses a table without them, and no other tool reaches this one. Adding them to make add_rows work here would let agent_02 write its own name and role. Do not.
   Note also that every agent can read it, so a real name here is visible to all of them. A role without a name (agent_05 = purchasing) gives the log its lookup without putting personal data in a shared store.';
comment on column public.agents.id is 'agent_01 .. agent_10, the same number as MCP_KEY_NN.';
comment on column public.agents.name is 'The person''s name, where known.';
comment on column public.agents.role is 'Free text, e.g. sales, finance, test.';
insert into public.agents (id) values ('agent_01'),('agent_02'),('agent_03'),('agent_04'),('agent_05'),
  ('agent_06'),('agent_07'),('agent_08'),('agent_09'),('agent_10')
on conflict (id) do nothing;
insert into public.agents (id, name, role) values ('service_role','Caretaker','system -- bulk loading, migrations, tidying')
on conflict (id) do update set name = excluded.name, role = excluded.role;

-- 4) Policies for the per-agent layer that does not exist yet. Inert today -- see the
--    note at the top of this file -- but the model is ready for the day it does.
--    Assumption: the layer sets the JWT claim "agent" to the same value as owner.
--
--    The claim is read straight from the PostgREST setting rather than through
--    auth.jwt(), which is only a wrapper around it. auth.jwt() lives in the auth schema,
--    which GoTrue brings up -- so a seed run against a database that has not finished
--    starting failed here with "function auth.jwt() does not exist", and a fresh deploy
--    is exactly that situation. Same semantics, one less thing that has to be up first.
drop policy if exists notes_read on public.notes;
create policy notes_read on public.notes for select to authenticated
  using (visibility = 'public' or owner = coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'agent', ''));
drop policy if exists notes_write on public.notes;
create policy notes_write on public.notes for all to authenticated
  using (visibility = 'public' or owner = coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'agent', ''))
  with check (owner = coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'agent', '') or visibility = 'public');

-- 5) The conventions, as a skill in the shared library.
-- Inserted only when the slug is absent, not "on conflict do nothing". Later files bump
-- this skill's version in place, so on a second run the 1.0.0 row no longer exists, a plain
-- insert would add a SECOND row for the same slug, and the next version bump would then try
-- to set both to the same version and hit the unique constraint. Found 2026-09-14 by running
-- the seed twice against an empty database -- the first run passed.
-- Created only when the slug is absent, and wrapped in a DO block so the values clause is
-- untouched. Later files bump this skill's version IN PLACE, so on a second run the original
-- version row is gone; a plain insert would add a SECOND row for the same slug and the next
-- bump would try to set both to the same version, hitting the unique constraint. Found
-- 2026-09-14 by running the seed twice against an empty database -- the first run passed.
-- The base of the conventions skill: section 0. The skill itself is published by
-- platform.assemble_conventions() at the end of the seed, as a new version whenever the
-- assembled text changes -- see the comment in platform.sql. This file used to insert the
-- whole skill and the later files edited it in place, which left the one document every
-- agent obeys without a single earlier version to show anyone.
--
-- The table is created here as well as in platform.sql, because this file runs first and
-- the DDL guard -- correctly -- refuses a table in public without the convention columns.
-- Both definitions are `if not exists` and identical.
create schema if not exists platform;
create table if not exists platform.convention_sections (
  ord        int primary key,
  name       text not null,
  body       text not null,
  updated_at timestamptz not null default now()
);
insert into platform.convention_sections as c (ord, name, body)
values (0, 'the conventions themselves', $md$---
    name: store-conventions
    description: Read this before you write anything to the shared store. It applies to every table in public.
    version: 1.0.0
    license: MIT
    ---

    # Shared store conventions

    The store is a shared workspace for several Hermes agents. Everyone can read and write public
    data. It must always be visible who did what, and private data belongs to its owner alone.

    ## Your identity

    You have an identifier: `agent_NN`, where NN is the number of your MCP key slot (`agent_01` ..
    `agent_10`). It is in your configuration, and `skillhub_whoami` will tell you what the gateway
    reads from your key. If you do not know it, ask the user before writing anything. Use it in
    `owner`, `created_by` and `updated_by`. Never invent a different one.

    Real names are attached to the identifier in the `agents` table, not repeated on every row.

    ## Search before you answer, not only before you write

    This is the rule that costs the most when it is skipped. Before you answer a question **from
    this data**, run `skillhub_search` and read what it returns. Someone may already have written
    down how this data has to be read -- which values are sentinels, which column is the reliable
    key, what has to be excluded from a total. Getting it wrong produces a confident wrong number,
    never an error, so nothing will tell you afterwards.

    Measured: the same question answered 1,091,957 without a search and 28,638 with one. Sixteen
    rows out of 5,812 made the difference, and a colleague had already documented them.

    ## Reading

    - Read whole objects with `skillhub_read` rather than working from a search excerpt.
    - The house tools filter on ownership for you: a private row belonging to another agent is
      simply not there. If you read with `execute_sql` instead, filter yourself:
      `where visibility = 'public' or owner = '<your identifier>'`.
    - Start from `skillhub_overview`. Tables and columns carry comments that explain them.

    ## Writing

    - Public is the default. Set `visibility = 'private'` only when the user asks for it.
      Private rows are not indexed for semantic search, so a private note cannot be found by
      meaning -- by you or by anyone.
    - On insert: fill `owner`, `created_by` and `updated_by` with your identifier.
    - On update: set `updated_by`. Leave `owner` and `created_by` alone.
    - Never change or delete another agent's rows. Public rows may be edited, but write down what
      you changed if it is not obvious.

    ## New tables

    - Create them with `select public.create_shared_table('<name>', '<description>')` and add your
      own columns with `alter table`. The table then has the standard columns, row security, the
      timestamp trigger, comments -- and the change log, which is the part that is invisible until
      it is missing.
    - A raw `create table` in public is refused if it lacks the four convention columns. The refusal
      tells you what to run instead.
    - Comment every new column, in English. The next agent reads the comments, not your session.
    - Unsure whether it should be a table at all? Run `select plattform.placement_rule()`.

    ## Files

    Do not store files in tables -- no base64 in columns. Files belong in Storage. Keep only a
    reference in the table: bucket, path, bytes, sha256. Register them with
    `skillhub_register_document` so the catalogue knows they exist.

    Note what a document record is and is not: it holds the filename and a description, not the
    file's contents. If someone asks what a document *says*, and the record shows the content is
    missing, say so. Do not answer from the filename.

    ## Not allowed without asking the user first

    - `drop table`, `truncate`, or `delete` without a `where`.
    - Changing `skill_library` other than adding or updating your own skills.
    - Changing policies, roles or privileges.
    $md$)
on conflict (ord) do update set name = excluded.name, body = excluded.body, updated_at = now()
 where c.body is distinct from excluded.body;

-- The house's own skills were authored as 'supabase-easy', the repository's old name. The
-- repository is skillhub since 2026-09-14; rows written under the old name are renamed once,
-- here, so overview and search show the same author the seed now writes.
update public.skill_library set author_name = 'skillhub' where author_name = 'supabase-easy';
