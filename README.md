# supabase-easy

Self-hosted Supabase for Easypanel, with the Studio **MCP server** opened up behind
per-person API keys so Hermes (or any MCP client) can read and write the data.

Upstream is Supabase's own self-hosting directory, `supabase/supabase` → `docker/`, pinned
in `UPSTREAM` (commit hash). Not the Easypanel template: that is a copy of the same
directory that was five months behind when this repo was made (Postgres 15 vs 17, Studio
April vs September 2026). Everything here that is not listed under "Changes" is upstream
verbatim and should be updated by diffing against `docker/` at a newer commit.

## Why a separate repo

Easypanel deploys its templates with `git reset --hard` against the template branch on
**every** Deploy. Anything edited under `/etc/easypanel/projects/<project>/<service>/code/`
is thrown away the next time you press the button — including an opened `/mcp` route,
and including the Postgres data directory if it lives under `./volumes/`. Deploying from
*this* repo (Compose service, Git source) makes the changes durable and moves state out
of the checkout. It is the same model as `openclaw-easy` and `hermes-easy`: a thin compose
wrapper around someone else's images, with the traps written down.

## Changes against upstream

| # | Where | What | Why |
|---|---|---|---|
| 1 | `docker-compose.yml` | Gateway is **Kong** (`kong/kong:3.9.3`), merged in from upstream's `docker-compose.kong.yml`; upstream's default is Envoy | Per-person keys are a solved problem in Kong (consumers + key-auth + acl). Envoy would need RBAC header policies plus custom stripping of empty slots. Upstream keeps Kong as an official override, so this is supported, not a fork. The Envoy config files stay in `volumes/api/envoy/` for a later switch. |
| 2 | `docker-compose.yml` | Gateway service is named `kong`, with `api-gw` and `envoy` as network aliases | Easypanel derives the Traefik/tunnel alias from the service name (`data_supabase_kong`); keeping it means no Cloudflare change on migration. Upstream configs that address `api-gw` still resolve. |
| 2b | `docker-compose.yml` + `example.env` | `kong` also joins the external `easypanel` network with alias `KONG_NETWORK_ALIAS` (default `data_supabase_kong`) | Easypanel only attaches a service to its shared network when the service has a Domain. A tunnel-only deployment has none, and cloudflared on that network must still resolve the alias; without this the tunnel answers 502 `no such host`. |
| 3 | `docker-compose.yml` | **No host ports.** Kong and Supavisor use `expose:` | Never publish a host port on an Easypanel host: a second instance then dies with `port is already allocated` while Easypanel reports success. Traefik and the tunnel reach container ports directly. |
| 4 | `docker-compose.yml` | Postgres data and Storage files are **named volumes** (`db-data`, `storage-data`) instead of `./volumes/db/data` and `./volumes/storage` | State must survive a re-clone. Other `./volumes/*` mounts are repo files (init SQL, Kong config, edge functions) and stay bind mounts on purpose. |
| 5 | `volumes/api/kong.yml` | `/mcp` route uses `key-auth` + `acl` (groups `admin`, `mcp`) instead of upstream's `request-termination` 403 | Upstream blocks MCP and suggests an IP allowlist, which does not work when clients are Swarm containers or laptops. A key is revocable per person. |
| 6 | `volumes/api/kong.yml` + `docker-compose.yml` + `example.env` | Ten consumers `agent_01` … `agent_10`, keyed by `MCP_KEY_01` … `MCP_KEY_10` from the environment, all in acl group `mcp`; `agent_NN` doubles as the agent's default identifier in the data | Keys live in Easypanel's Environment panel, no YAML edits per person. Group `mcp` is only allowed on `/mcp`, so these keys are useless against `/rest/v1`, `/auth/v1`, `/storage/v1`. |
| 7 | `volumes/db/roles.sql` | Also sets the password of `supabase_read_only_user` | Upstream never does, so Studio's MCP `list_tables` fails with *password authentication failed* on a fresh install. Applies at first init only; for an existing database see "Known traps". |
| 8 | `volumes/api/kong-entrypoint.sh` | Also strips `- key: $VAR` lines whose variable was never substituted | Upstream only strips *empty* keys. A slot missing from the container env would otherwise be left as the literal text `$MCP_KEY_03`, a valid and guessable API key. |

Not included from upstream: the logs stack (`docker-compose.logs.yml`: Logflare analytics
and Vector, roughly 700 MB of RAM), the proxy variants (Caddy/Nginx), and the S3/RustFS
storage backends. Studio's `get_logs` MCP tool needs the logs stack; merge that file in
if you want it. `run.sh`/`setup.sh`/`update.sh` are omitted because Easypanel is the deployer.

## Deploy on Easypanel

1. Create a **Compose** service, source = this Git repo, compose path `docker-compose.yml`.
   Use project `data` and service name `supabase` if you want the alias `data_supabase_kong`
   (what the Cloudflare tunnel points at) and volume names `data_supabase_db-data` etc.
2. Paste `example.env` into the service's Environment panel and set **every** secret before
   the first deploy (see "Known traps"). `utils/generate-keys.sh` produces a full set. Set
   `SUPABASE_PUBLIC_URL`, `API_EXTERNAL_URL` and `SITE_URL` to the public domain, and
   `REALTIME_DB_ENC_KEY` to exactly 16 characters (`openssl rand -hex 8`).
3. Deploy. No Domain is needed when a Cloudflare tunnel points at `KONG_NETWORK_ALIAS`; add a Domain on `kong` port `8000` only if you want a Traefik path too. Studio, REST,
   Auth, Storage and `/mcp` are all behind it.
4. MCP keys: set `MCP_KEY_01=<openssl rand -hex 32>` etc. and Deploy again. Clear a value
   to revoke it; the other slots are unaffected.

Easypanel generates `.env` and `docker-compose.override.yml` in the deploy directory. Both
are gitignored here; never commit them.

### Which layer picks up a change, and when

Three layers, three different answers. Getting this wrong is how a fix appears to fail, or
worse, appears to work.

| Layer | File | Read when | To apply a change |
|---|---|---|---|
| Gateway | `volumes/api/kong.yml` | **container creation** | recreate Kong — a restart keeps the old routes, consumers and ACL in memory |
| MCP server / indexer | `volumes/functions/*/index.ts` | container start | restart `supabase-edge-functions` |
| Tool logic, rules, views | `demo/*.sql` | **every call** | apply with `psql`; effective immediately |

The third row is the one that surprises people. The fifteen tools are thin: the edge function
reads the verified agent from Kong's header, overwrites the `agent` argument with it, and
calls a Postgres function. Almost everything an agent experiences — the rules it reads, what
a refusal says, what a tool will and will not do — is SQL, and changing it needs no deploy at
all. Which also means the database can be running SQL that exists in no file. Re-apply from
`demo/` after editing and keep the two in step.

### Setting up a new instance: three steps

A deploy of this repo gives you Supabase, the gateway with `/skillhub`, and the ten key
slots. The data store itself — the conventions, the change log, the placement rule, the
fifteen tools — is `demo/*.sql`, and it is applied by the `seed` service on every boot.

1. **Deploy** (see above). Paste the environment, deploy, set the `MCP_KEY_NN` slots you
   need, and **recreate Kong** so it renders them.
2. **The seed runs itself.** `docker logs supabase-seed` shows nine files and `ok` after
   each. It runs again on every boot: every statement is create-or-replace or
   if-not-exists, so an up-to-date database is untouched. That is deliberate — it is what
   keeps the database from drifting away from the repo the way a hand-applied schema does.
3. **Hand out a key**: `sh utils/make-agent-invite.sh agent_04 https://<domain>` and paste
   the result into that person's agent. `skillhub_whoami` should answer `agent_04`.

Three things a new environment trips on, all measured:

- **Semantic search and index-on-write are off until `EMBEDDING_URL` and `EMBEDDING_KEY` are
  set.** `prepare-easypanel-env.sh` leaves them empty on purpose (they are your provider's
  key), and nothing fails loudly without them: keyword search still works, `skillhub_similar`
  reports that it is off, and new content becomes findable on the five-minute cron instead of
  in about three seconds. Set them before anyone measures the store.
- **Keys present at the first deploy need no extra step; keys added later do.** Kong renders
  its list of permitted callers when the container is created. A fresh deploy creates it with
  whatever `MCP_KEY_NN` the panel holds. Filling a slot afterwards requires *recreating* Kong,
  not restarting it — a restart keeps the old list in memory and the new key answers 401.
- **Behind a Cloudflare tunnel, a client must send a User-Agent.** The edge's browser-integrity
  check answers HTTP 403 `error code: 1010` to Python's default `Python-urllib/…` before the
  request reaches the gateway. Hermes (`python-httpx2/…`) passes; a hand-rolled script may not.
  Eleven of fourteen protocol checks failed that way on a server that was fine.

**[VERIFY.md](VERIFY.md)** lists every receipt in the order to run them, what each proves, and what to do when one fails. The first one, without touching anything real:

```sh
sh utils/test-seed-on-empty-db.sh
```

It raises an empty database from the same image, seeds it twice, and checks that the store
answers: the tables carry the conventions, the fifteen tools exist, the rules are readable,
a write through the tool tier lands under the caller's identity, and the change log caught
it. That is the receipt that a fresh deploy works.

**Ownership, once, on an instance that predates the seed.** The seed connects as `postgres`
because `supabase_admin` has no password set. Objects applied by hand as `supabase_admin`
cannot then be replaced, so align them once — as `supabase_admin`, which is the superuser:

```sql
-- functions, views, tables, sequences in public and platform -> postgres
-- then, because an event trigger's owner cannot be changed, drop and let the seed recreate:
drop event trigger if exists platform_ddl_guard;
drop event trigger if exists platform_ddl_guard_drop;
```

A fresh install needs none of this: the seed creates everything as `postgres` from the start.

### Running a second instance on the same host

Useful for proving a clean install without touching a working one, and necessary on any
Easypanel that already runs a Supabase. Three things would collide, and only one of them
needed fixing:

| | |
|---|---|
| Volumes | already safe — named volumes get the compose project prefix |
| Gateway alias | already a variable — `KONG_NETWORK_ALIAS` |
| **Container names** | were hardcoded twelve times; now `CONTAINER_PREFIX` (default `supabase`) |

So a second instance is a new Easypanel service from this repo with a different project or
service name, and in its Environment: `CONTAINER_PREFIX=sbtest`, a different
`KONG_NETWORK_ALIAS`, its own domain or tunnel, and its own secrets. Nothing else changes,
and the default keeps the names a single instance has always had.

Budget about 1.1 GiB of memory for a full stack, measured on a live one.

### The gateway: Kong, deliberately, for now

Upstream Supabase made Envoy the default API gateway in August 2026 and moved Kong to an
optional override (`docker-compose.kong.yml`), noting that the OSS Kong line is no longer
actively maintained and that a customised `kong.yml` does not carry over — it silently stops
applying. This repository runs Kong on purpose, and the reason is the one thing that is
Kong-specific here: **per-agent identity**. Ten consumers with API keys, ACL groups on the two
routes, and the `X-Consumer-Username` header that every writing tool takes its identity from.
Upstream's Envoy configuration is a 27-line stub that translates the new `sb_*` key scheme
into JWTs; it has no per-key identity of its own. Porting is an `ext_authz` filter or a static
key-to-header map plus the two route ACLs — a contained piece of work, not a rewrite — and it
is on the list. Until then, updating from upstream means keeping the Kong override, and the
gateway is the one component here that will not get upstream's security hardening for free.

### MCP protocol: both eras

The server speaks MCP `2026-07-28` (stateless, per-request `_meta`, `server/discover`) and
the legacy `initialize` handshake side by side. A dual-era client such as Hermes probes modern
first and falls back only if the probe fails; until `server/discover` existed here, every
client fell back and nobody noticed. `utils/test-mcp-protocol.py` checks both paths, the
required `resultType`, the cache hints on `tools/list`, and the two error codes the spec says
must travel with HTTP 400.

### Two clones, and the one that is actually running

You edit here. The containers mount the clone Easypanel pulls into
`/etc/easypanel/projects/<project>/<service>/code/`. Editing here changes nothing until you
commit, push and deploy — and editing **there** changes everything immediately while git knows
nothing about it.

```sh
sh utils/check-deployed-drift.sh
```

Run it before and after every deploy. It reports how far behind the deployed checkout is,
which files were edited in place, and whether the files the containers read match what you
would deploy.

It exists because on 2026-09-14 the deployed checkout turned out to be 29 commits behind and
dirty: three files edited in place, one of them `volumes/api/kong.yml` carrying the rule that
closed the raw SQL door to agent keys. That rule — the single change that made ownership mean
anything — existed only as an uncommitted edit on a server. Pressing Deploy would have
restored the committed version and reopened the door silently, with no diff and no error, and
the next person to check would have found agents writing rows under each other's names again.
Nothing was lost, but only because the contents happened to match. It was noticed by accident.

## The house MCP server (`/skillhub`)

Supabase's own MCP server has eleven fixed tools and cannot be extended without forking
Studio. Tool descriptions are also the only text guaranteed to be in an agent's context on
every turn — stronger than table comments, which require a `list_tables` call, and stronger
than skills, which require the agent to fetch them. So work that must be easy to get right
lives in a second MCP server of our own: the edge function in `volumes/functions/skillhub`,
routed by Kong at `/skillhub` behind the same `apikey` header and the same consumers.

It **adds to** Supabase MCP rather than replacing it. `execute_sql` is what let an agent
invent a good ingestion pattern on its own; the tools are for the work that should come out
the same every time. Point an agent at both.

Eleven tools: `skillhub_overview`, `skillhub_search`, `skillhub_rules`, `skillhub_read`,
`skillhub_similar`, `skillhub_activity`, `skillhub_write_note`, `skillhub_publish_skill`,
`skillhub_register_document`, `skillhub_whoami`, `skillhub_report`. `/lager` stays as a Kong
alias until every agent has switched.

`skillhub_read` is the counterpart to the two searches: they say *which* object, it returns
*all* of it. That is the deliberate split — retrieval finds like RAG, reading happens whole
like CAG, so no answer is ever built from a fragment without its context. It works because
the objects are small; the largest skill is under 8 000 characters. It stops working the day
document text is loaded, and that is the next design decision: chunk to find but return the
surrounding section, or embed a generated summary and fetch the original on demand.

**Language.** Everything built from 2026-09-10 is in English, and the agent-facing surface was
renamed in one move while only two agents were connected. The `plattform` schema internals and
the Swedish skills already written by agents are deliberately not renamed: they are invisible
to the tool surface, and rewriting triggers, the DDL guard and other people's content is a
separate and riskier job.

One measurement shaped these tools, and it is worth repeating before writing more of them:
with many tools connected, Hermes puts MCP tools in a **deferred** pool. The agent sees the
tool name and roughly the first 60 characters of the description, and loads the full schema
only after choosing the tool. The server's own `initialize` instructions never reach the
context at all. So a rule an agent must not miss belongs in the system prompt (hermes-easy
seeds it into `SOUL.md`) or in a constraint it cannot get around — never only in a tool
description. Every description here front-loads its instruction into the first clause.

**Identity is verified here, unlike through `execute_sql`.** Kong's key-auth sets
`X-Consumer-Username` on the way upstream, so the function knows which `agent_NN` the key
belongs to and fills `owner`/`created_by` from that. Tested: a call carrying agent_02's key
and claiming `"agent": "agent_99"` in its arguments wrote a row owned by `agent_02`. Writes
made with raw SQL remain self-reported — that difference is the argument for moving routine
writes to the tools.

The function has no external imports: it reaches the database through PostgREST with the
service key that is already in its environment, calling `public.skillhub_*` wrappers because
PostgREST only exposes `public`. A parameter without a default must be sent, or PostgREST
reports the function as missing — that bit the first version.

## Using the MCP endpoint

Endpoint: `https://<kong-domain>/mcp`, streamable HTTP. Authentication is the header
`apikey: <key>` — **not** `Authorization: Bearer`. Kong's key-auth only reads `apikey`;
a Bearer token is ignored and answered with `401 No API key found in request`.

Accepted keys: any `MCP_KEY_NN` (consumer `agent_NN`), or the project's `SERVICE_ROLE_KEY` (acl group `admin`).
Do not hand out the service role key — it also unlocks REST, Storage and Auth admin, and
rotating it means redeploying every service.

Hermes Agent, `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  supabase:
    url: "https://<kong-domain>/mcp"
    headers:
      apikey: "${SUPABASE_MCP_KEY}"
    enabled: true
    timeout: 120
```

Then `/reload-mcp`. Tools exposed by Studio's server: `list_tables`, `execute_sql`,
`apply_migration`, `list_migrations`, `list_extensions`, `get_logs`, `get_advisors`,
`get_project_url`, `get_publishable_keys`, `generate_typescript_types`, `search_docs`.

### What a key does and does not control

Kong decides **who** reaches `/mcp`. It does not decide **what** they may do: Studio's MCP
server runs every call as the database administrator, regardless of which key let the
request in. Every holder of an `MCP_KEY_NN` can read all tables, write all tables, and
run DDL through `apply_migration`. Row level security does not apply to them.

That is fine for a shared read/write workspace among a few trusted people, which is what
this repo is for. It is not a multi-tenant boundary. When per-user permissions are
needed, the answer is a separate MCP service that authenticates the user against Supabase
Auth and queries with the user's JWT, so RLS applies — not more Kong rules.

Client-side mitigation (a user can remove it, so treat it as guidance, not a control):

```yaml
    tools:
      exclude: [apply_migration]
```

## Semantic search

`plattform.inbaddningar` holds one vector per object per model, and the `embed` edge function
keeps it current: every five minutes pg_cron calls it through pg_net, it asks
`embed_kandidater` what lacks a current embedding, sends the texts to the endpoint in
`EMBEDDING_*`, and writes the vectors back. Agents never see any of it — they write a note
and it becomes findable by meaning a few minutes later. That is the AnythingLLM division of
labour: whoever owns ingestion owns the index. Putting the endpoint in each agent's prompt
would instead produce an index reflecting which agent remembered, and spread the key to
every laptop.

`text_hash` makes it idempotent: edited text is re-embedded, unchanged text is skipped.
The model name is stored per row because vectors from different models must never be
compared; `demo/plattform_vektor.sql` rebuilds the column for a different dimension and
refuses while rows exist.

**Whole objects, not chunks.** A skill, a note or a document record is one vector.
Retrieval returns an identifier and the agent then fetches the whole thing, so nothing is
lost at a chunk boundary. The cost is that a long document blurs into one vector — fine
here, because the document rows carry filename and description, not the file's text.

**Structured tables are deliberately not embedded.** "How many NCRs did this supplier
cause last year" is a `group by`, not a similarity search, and vector search would answer it
worse. The agent picks the mode: `skillhub_sok` for words, `skillhub_liknande` for meaning,
`execute_sql` for facts.

Measured on the live store, 486 objects embedded with `text-embedding-3-small`: "hur
hanterar vi missnöjda kunder" returns the complaint skill at 0.49 although neither phrase
shares a word with it. Scores sit between 0.35 and 0.5 for good hits — with this model on
Swedish, treat results as leads to open, not as answers.

## Known traps

**Secrets must be final before the first deploy.** Postgres role passwords are set by the
init scripts on an *empty* data volume only. Change `POSTGRES_PASSWORD` afterwards and
every service except `db` restart-loops with `password authentication failed`, while the
env looks consistent. Fix without wiping: inside the `db` container as `postgres`, run
`ALTER USER <role> WITH PASSWORD '<new>'` for `postgres`, `supabase_admin`, `authenticator`,
`pgbouncer`, `supabase_auth_admin`, `supabase_functions_admin`, `supabase_storage_admin`,
`supabase_read_only_user`.

**Existing database, `list_tables` fails.** Databases initialised by upstream or the
Easypanel template lack a password on `supabase_read_only_user`. One-off fix (the secret
never leaves the container):

```bash
docker exec <db-container> sh -c 'psql -U postgres -c "ALTER USER supabase_read_only_user WITH PASSWORD '"'"'$POSTGRES_PASSWORD'"'"'"'
```

**Tables created via `execute_sql`/`apply_migration` have no RLS.** Supabase grants
`anon` and `authenticated` full privileges on new tables in `public` by default, and Kong
exposes `/rest/v1` on the same domain. A table created by an agent is readable *and
writable* by anyone holding the anon key until `ALTER TABLE … ENABLE ROW LEVEL SECURITY`
is run. Views need `ALTER VIEW … SET (security_invoker = true)` or they bypass RLS on the
tables underneath. Make RLS-on part of every migration from day one.

**Files belong in Storage, not in tables.** An agent that base64-chunks a spreadsheet into
a table through `execute_sql` works, but each multi-hundred-kB statement can make Studio
drop the connection (Kong logs `upstream prematurely closed`, the client sees 502).

**Kong needs the variable in `docker-compose.yml`.** `kong-entrypoint.sh` substitutes
`$NAME` in `kong.yml` from the *container's* environment, not from `.env`. A new key slot
requires both the `MCP_KEY_xx: ${MCP_KEY_xx:-}` line under `kong` and the consumer in
`kong.yml`. Empty or unset values are stripped by the entrypoint.

**Studio MCP is an internal-only feature upstream.** Supabase's own docs say not to expose
it to the internet at all. This repo does, behind Kong key-auth over TLS, and in practice
only through a Cloudflare tunnel. Keep the key list short and watch Kong's access log for
`POST /mcp` with 401s — that is what a wrong header or a revoked key looks like.

## Clean start

When nothing from an existing install needs keeping, skip the migration:

1. Push this repo; in Easypanel delete the template service `data/supabase`, then remove
   the volume it leaves behind (`docker volume rm data_supabase_db-config`).
2. Create a Compose service `data/supabase` from this repo. Environment: on any machine
   with this checkout and `openssl`, run
   `sh utils/prepare-easypanel-env.sh https://<public-domain> <dashboard-user> 2`
   — it fills every secret via `generate-keys.sh`, sets the three public URLs and two
   `MCP_KEY_xx` slots, and writes the result to `$HOME/.supabase-secrets/`, **never** into
   the checkout. Paste the file into the Environment panel, Deploy, then `shred -u` it.

   The script refuses to write into any git working tree, checked before it generates
   anything. That guard exists because an earlier version wrote the file here and
   `git add -A` pushed it: every secret plus the public URL, in a public repository. The
   pair is what matters — a key alone is a guess, a key with its endpoint is an open door.
   If it ever happens again: rotate first, purge history second, in that order.
3. Seed the shared-data layer, in this order (`docker exec -i <db> psql -U supabase_admin -d postgres < demo/<file>.sql`;
   `plattform.sql` onwards must run as a superuser because of the event trigger):

   | File | What it adds |
   |---|---|
   | `skill_library.sql` | the shared skill registry |
   | `conventions.sql` | `create_shared_table()` with owner/visibility/created_by/updated_by, row security, timestamps, the `agents` table, and the conventions as a skill every agent loads |
   | `platform.sql` | the `platform` schema: change log, catalog, keyword search, pgvector scaffolding, the placement rule, and an event trigger that refuses tables which ignore the convention |
   | `platform_lifecycle.sql` | skill lifecycle (confirm / retire / superseded_by), the `documents` catalogue, the going-stale list, and `platform.daily_report()` |
   | `platform_loading.sql` | the delivery register (`deliveries`, `v_sources`) and the loading house standard as a skill |
   | `platform_entry.sql` | `start_here`, the entry point that shows up in `list_tables`, plus rule-bearing table comments |
   | `platform_tools.sql` | the eleven `skillhub_*` RPC functions the house MCP server exposes |
   | `platform_embed.sql` | embedding support: candidates, storage, semantic search, and the pg_cron job that keeps the index current |
   | `platform_vector.sql` | only if your embedding model is not 1536 dimensions -- changes the vector column before anything fills it |

   The order matters: each file builds on the names the previous one created.

   Nothing in this list is business data. These files are the walls and the door; what
   moves in is the agents' business. An agent loads the organisation's own data by
   following the `load-from-source-system` skill.

   Start every session with `skillhub_overview` -- or `select * from platform.overview();`
   over raw SQL. It says what is in the store, who else is connected, and what needs
   cleaning.
4. Add `MCP_KEY_NN` values, Deploy, and give each agent its key with the config block under
   "Using the MCP endpoint" plus its identifier `agent_NN` (same NN as the key slot) in its
   configuration. Every agent is a plain user; administration happens through Studio or
   `psql`, never through an agent with the service role key.

## Migrating from the Easypanel template (Postgres 15 → 17)

The template's data lives in `./volumes/db/data` on Postgres 15; this repo initialises a
fresh Postgres 17 cluster in `db-data`. A data directory cannot be reused across major
versions, so the path is dump → deploy → restore:

1. From the running template: `docker exec <db> pg_dumpall -U postgres > supabase.sql`
   (or `pg_dump -U postgres -d postgres` for the application database only).
2. Copy the old service's Environment values into the new service — same `JWT_SECRET`,
   `ANON_KEY`, `SERVICE_ROLE_KEY`, `POSTGRES_PASSWORD` — and add `REALTIME_DB_ENC_KEY`.
   Same keys means existing MCP clients keep working and the dump's roles match.
3. Remove the template service, create this one under the same project/service name,
   Deploy, wait for `db` healthy.
4. Restore: `docker exec -i <db> psql -U postgres < supabase.sql`. Expect harmless
   "already exists" errors for roles and extensions the init scripts created.
   `supabase_migrations.schema_migrations` comes with the dump, so `list_migrations`
   history survives.
5. Re-run the `supabase_read_only_user` fix if the dump overwrote the role, then check
   `list_tables` through `/mcp`.

If the database is small and reproducible from migrations, skipping the dump and
re-applying the migrations through MCP is simpler.

## Updating from upstream

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase.git /tmp/sb
git -C /tmp/sb sparse-checkout set docker
diff -r /tmp/sb/docker/volumes volumes          # init SQL, Kong, functions
diff /tmp/sb/docker/docker-compose.yml docker-compose.yml
diff /tmp/sb/docker/.env.example example.env
```

Carry the eight changes above across, update `UPSTREAM`, validate as below, commit with
the upstream commit hash in the message.

## Verifying a change

```bash
docker compose -f docker-compose.yml --env-file <path-to-.env> config   # substitution + schema
# Kong config after env substitution, parsed by Kong itself:
docker run --rm -u root -v "$PWD/volumes/api:/cfg:ro" -e KONG_DATABASE=off -e KONG_ROUTER_FLAVOR=expressions \
  -e MCP_KEY_01=x -e SUPABASE_ANON_KEY=a -e SUPABASE_SERVICE_KEY=s -e DASHBOARD_USERNAME=u -e DASHBOARD_PASSWORD=p \
  -e KONG_DECLARATIVE_CONFIG=/tmp/kong.yml --entrypoint sh kong/kong:3.9.3 -c \
  'mkdir -p /home/kong && cp /cfg/kong.yml /home/kong/temp.yml && sed "s#exec /entrypoint.sh kong docker-start#true#" /cfg/kong-entrypoint.sh > /tmp/ep.sh && sh /tmp/ep.sh && kong config parse /tmp/kong.yml'
```

Smoke test after deploy, from anywhere:

```bash
curl -s -X POST https://<kong-domain>/mcp -H 'apikey: <MCP_KEY_01>' \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
```

Expect `"serverInfo":{"name":"supabase"…}`. Without the header expect 401; with the anon
key expect 403 `You cannot consume this service`; with an `MCP_KEY_NN` against
`/rest/v1/<table>` expect 403 from Kong. `/storage/v1` and `/functions/v1` have no key-auth
in Kong (the services validate JWTs themselves), so an `MCP_KEY_NN` there is rejected by the
service with 400 `Invalid Compact JWS` — same outcome, different status code.
