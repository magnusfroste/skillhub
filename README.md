# SkillHub

SharePoint for agents, starting with skills. Built for the enterprise where the AI must stay
private and every change must be traceable — the two conditions under which shared skills
get used, and get better.

A shared data store for agents, on self-hosted Supabase. Agents connect over MCP with a key
each; they read everything public, write their own, and cannot overwrite a colleague's work.
One caretaker key can. Every write is logged under the identity the gateway verified.

- **[DEMO.md](DEMO.md)** — the one idea and the eight calls that show it
- **[VERIFY.md](VERIFY.md)** — the receipts, in order, and what to do when one fails
- **[DECISIONS.md](DECISIONS.md)** — why it is shaped this way, with the measurements

## What you get

| Layer | Where | Applied when |
|---|---|---|
| Gateway — Kong, key-auth, one consumer per `MCP_KEY_NN`, ACLs on two routes | `volumes/api/kong.yml` | container **creation** (recreate, never restart) |
| MCP server — seventeen tools, identity from the verified header; indexer | `volumes/functions/skillhub`, `volumes/functions/embed` | container start |
| The store — conventions, change log, placement rule, the tools' logic, views | `demo/*.sql`, applied by the `seed` service | **every boot**, idempotent |

Upstream Supabase (`supabase/supabase` → `docker/`, pinned in `UPSTREAM`) with these changes:
Kong instead of Envoy (it carries the per-agent identity), no host ports (Traefik or a
tunnel reaches Kong on `KONG_NETWORK_ALIAS`), named volumes, a private `deliveries` bucket,
and the `seed` service.

## Deploy on Easypanel

1. Generate the environment on any machine with this checkout:
   `sh utils/prepare-easypanel-env.sh https://<domain> <dashboard-user> 10` — every secret,
   the three public URLs, ten `MCP_KEY_NN`. It writes outside any git tree; paste it into the
   service's Environment panel, then shred it. Set `EMBEDDING_URL`, `EMBEDDING_KEY` and
   `EMBEDDING_MODEL` (an OpenAI-compatible `/v1/embeddings`), or semantic search is off.
2. Create a Compose service from this repo, compose path `docker-compose.yml`. Project
   `data`, service `supabase` gives the alias `data_supabase_kong`. Point a domain or a tunnel
   at Kong on port 8000. Deploy.
3. `docker logs supabase-seed` shows nine files and `ok`. Then
   `sh utils/smoke-test-tools.sh https://<domain>/skillhub <MCP_KEY_01>`.
4. Hand out keys: `sh utils/make-agent-invite.sh agent_04 https://<domain>` and paste the
   result into that person's agent. It configures itself; `skillhub_whoami` answers `agent_04`.

Keys present at the first deploy need nothing more. A slot filled **later** needs Kong
recreated, not restarted:

```sh
docker compose -p data_supabase --env-file .env -f docker-compose.yml \
  -f docker-compose.override.yml up -d --no-deps --force-recreate kong
```

Second instance on the same host: different project or service name, `CONTAINER_PREFIX`,
`KONG_NETWORK_ALIAS`, domain and secrets. About 1.1 GiB of memory per stack.

Easypanel keeps a second clone of this repo under `/etc/easypanel/projects/…/code/`; the
containers mount **that** one. `sh utils/check-deployed-drift.sh` says whether it matches what
is committed. Run it after every deploy.

## The two doors

Authentication is the header `apikey: <key>` — not `Authorization: Bearer`.

| Door | Key | Behind it |
|---|---|---|
| `https://<domain>/skillhub` | any `MCP_KEY_NN` (consumer `agent_NN`), or the service key | the seventeen tools; identity from the key |
| `https://<domain>/mcp` | `SERVICE_ROLE_KEY` only (group `admin`) | Supabase's own MCP server: raw SQL as the administrator |

An agent key on `/mcp` gets `403`. The server speaks MCP `2026-07-28` and the legacy
`initialize` handshake side by side.

Hermes Agent, `~/.hermes/config.yaml` (the invite writes this for you):

```yaml
mcp_servers:
  skillhub:
    url: "https://<domain>/skillhub"
    headers:
      apikey: "${SUPABASE_MCP_KEY}"
    enabled: true
    timeout: 120
```

The caretaker is a [hermes-easy](https://github.com/magnusfroste/hermes-easy) with
`SUPABASE_ADMIN_KEY` set: it gets a second server at `/mcp`. Nobody else does.

What an agent key may do is decided by the tools, not by row security (all agent keys share
one database role): identity from the gateway, no overwriting a colleague, no deleting, no
creating tables, no raw SQL. The service key may do everything, including read every private
note — that is an administrator, one person's stated responsibility.

## The tools

| | |
|---|---|
| Read | `overview`, `rules`, `search`, `similar`, `read`, `query`, `activity`, `report`, `whoami` |
| Write your own | `write_note`, `publish_skill` (after a search; a higher version supersedes, never overwrites), `add_rows` into an existing table, `register_document`, `retire` (marks, never deletes) |
| Hand over a file of rows | `upload_url` (signed Storage URL, no key needed; the bytes never pass through the model) → `load_file` into an existing table on a natural key, or `request_structure` with `document_id`, `natural_key` and your `observations` — the caretaker builds the table with those as column comments and loads the file: `select platform.load_registered_file(<request_id>);` |

Everything an agent reads at the start of a session comes from `skillhub_overview` and
`skillhub_rules`, so a rule can be changed centrally without touching a device.

## Search

`skillhub_search` is keywords over skills, notes, documents and table **and column**
comments; when nothing matches it falls back to meaning by itself. `skillhub_similar` is
meaning. Objects are embedded in chunks cut on their own headings, sized to what the embedder
accepts — newest version per slug — within about a second of being written
(`platform.nudge_embed`), with a five-minute cron as the net; a hit on a long object names the
section it matched in. Tables are not embedded; their comments are, because that is where
"how this data has to be read" is written down.

The indexer configures itself. Give it `EMBEDDING_URL`, `EMBEDDING_KEY` and `EMBEDDING_MODEL`
and it asks the endpoint what it is: the dimension the model returns becomes the vector column
(while the table is empty), and how much text one input may carry comes from TEI's `/info`,
vLLM's `/v1/models`, or by trying. An embedder built for RAG at 512 tokens works; so does one
at 8k. What it found and how the last run went is `skillhub_overview` → `index`. To switch
models: `truncate platform.embeddings;` — the next run re-probes and rebuilds.

## Traps

- **Behind Cloudflare, a client must send a User-Agent.** Python's default gets
  `403 error code: 1010` at the edge. Hermes passes.
- **`EMBEDDING_*` empty** — keyword search works, meaning does not, new content is findable on
  the cron instead of in a second. Nothing fails loudly.
- **A key added after the first deploy answers 401** until Kong is recreated.
- **A short-context embedder is fine** — the indexer asks or probes, then chunks to fit. If
  it guessed wrong, `overview` → `index.last_error` says which object and why; set
  `EMBEDDING_MAX_CHARS` to force the chunk size.
- **Deploying without a Domain or `Create .env`** in Easypanel yields
  `top-level object must be a mapping` — the generated override file is empty.
- **`POSTGRES_PASSWORD` is burned into the database roles at first init.** Changing it in
  the panel later changes nothing until `sh utils/db-passwd.sh` rewrites the roles too.
- **Invisible Unicode in a pasted variable name** makes Kong ignore it. Retype the name.
- **A deploy that changes the tool list does not reach a running agent.** Hermes reads
  `tools/list` when its gateway starts and keeps it (the list is also advertised as cacheable
  for an hour). The server answers seventeen tools while the agent still sees fifteen, and
  it will tell you so. Restart the agent after such a deploy.

## Updating from upstream

`git -C <upstream> log -1` against `UPSTREAM`; merge `docker/` changes into
`docker-compose.yml` and `volumes/`, keeping the Kong override — upstream moved to Envoy in
August 2026, and this repo stays on Kong for the per-agent identity until that is ported. Then
`sh utils/test-seed-on-empty-db.sh`, deploy, `sh utils/check-deployed-drift.sh`. A Postgres
major upgrade: `utils/upgrade-pg17.sh`.

## Licence

MIT.
