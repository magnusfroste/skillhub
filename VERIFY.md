# Verifying your installation

Six receipts, in the order they should be run. Each one answers a different question, and
each one exists because the answer was once wrong while everything looked fine. Run them in
this order the first time; run the ones that apply after any change.

| # | Question | Receipt | Touches your instance? |
|---|---|---|---|
| 0 | Will search by meaning work against your embedder? | `utils/check-embedder.sh` | No — before you install anything |
| 1 | Does this repository build a working store from nothing? | `utils/test-seed-on-empty-db.sh` | No — a throwaway database |
| 2 | Is what is running what is committed? | `docker logs supabase-seed` + `utils/check-deployed-drift.sh` | Read-only |
| 3 | Do the chat tools answer through the gateway? | `utils/smoke-test-tools.sh` | Writes, then retires what it wrote |
| 4 | Does the server speak the current MCP revision, and the legacy one? | `utils/test-mcp-protocol.py` | Read-only |
| 5 | Does a real client adopt the current revision? | `utils/probe-mcp-era.py` | Read-only, run inside a client |

Then one thing no script can do for you: ask an agent a question whose answer you know.

And afterwards, for as long as the store is running:

```sh
sh utils/health.sh https://<store> "$SERVICE_ROLE_KEY"            # a person
sh utils/health.sh https://<store> "$SERVICE_ROLE_KEY" --quiet    # cron: silent unless broken
```

One call, one verdict, and for each check what is true and the call that deals with it. It
exits non-zero **only** when something is broken — work waiting is not an incident, and a
check that fires on work stops being read. The caretaker sees the same thing inside
`skillhub_overview`, because it holds the service key.

---

## 0. Before you install: `check-embedder.sh`

```sh
sh utils/check-embedder.sh http://10.0.0.5:8008/v1/embeddings embed
```

Run it **from the machine that will host the store**, not from a laptop. It asks the
endpoint what the indexer will ask it, in the same order, and prints what the store would
conclude: the dimension the model returns and therefore which index the vector store gets,
the input limit it reports, characters per token measured on this store's kind of text and
the chunk size that follows, whether a batch of eight is accepted, and what happens to an
input over the limit — refused, cut by itself, or cut on request.

It changes nothing and needs no database. Measured against a client's Qwen3-Embedding-8B on
vLLM: 4,096 dimensions and therefore no index, 2,048 tokens from `/v1/models`, 4.12
characters per token, a 7,163-character chunk, eight inputs fine, over-limit refused with
400 and `truncate_prompt_tokens` accepted.

Why it exists: half of what goes wrong with a private embedder is that it answers from
where you tested and not from where the container runs, and the store's way of saying so is
`the endpoint answered 404` — five minutes later, in a cron.

---

## 1. From nothing: `test-seed-on-empty-db.sh`

```sh
sh utils/test-seed-on-empty-db.sh
```

Raises an empty Postgres from the same image the stack uses, seeds it, seeds it **again** (the
seed runs on every boot, so a second run has to be a no-op), and then checks that the store
*answers* — forty-six checks, from "the tables carry the convention columns" to "a skill
published through the gate can be retired by its author and ends up deprecated, not deleted".

Among them, the path a first install takes on a model that is not 1,536-dimensional, because
that is what a client's own embedder usually is: the table is built at 1,536 with an HNSW
index, the indexer's first run probes and calls `platform.set_vector_dim`, and everything
downstream has to follow — including **the next boot's seed**, which is where this failed
until 2026-09-16. Checked at 4,096 (no index, exact scan), at 3,072 (half-precision index)
and back at 1,536, with a seed run in the middle and the tools answering at each.

Expect: `PASS -- an empty database and this repo give a working data store.`

Why it exists: every earlier apply had been against a database where the objects already
existed. The first run of this test found five defects a fresh install would have hit and
nobody had, including six columns that were in production and in no file. A later run found a
function that the repo's own caller invoked with four arguments and the repo's own definition
took with three — every skill retirement failed on a fresh install, and the test had passed
because it never retired a skill. It does now. Nothing here is visible by reading.

Needs Docker on the machine you run it from. Takes about a minute.

## 2. What is actually running: the seed log and the drift check

```sh
docker logs supabase-seed
sh utils/check-deployed-drift.sh          # on the host, from the working checkout
```

The seed log should show nine files and `ok` after each, ending in `Done. Re-running this
changes nothing on an up-to-date database.` If a file says `FAILED`, the message under it is
the cause; the store is incomplete until it passes, and it is safe to re-run by hand.

Then `skillhub_overview` → `index`, as any agent: expect `meaning_search: on`, the model and
dimension the indexer found, `waiting: 0` and `last_error: null`. That is the embedding
receipt; the indexer probes the endpoint itself, so a wrong guess shows up here, not in a log.

The drift check compares the clone you edit with the clone the containers mount. Expect
`deployed is 0 commit(s) behind`, `none` under in-place edits, and `same` for the four files
the containers read. Anything else means what is running is not what git says — which is how
a rule that closed the raw SQL door once lived only as an uncommitted edit on a server, one
Deploy away from silently reopening it.

## 3. Every tool, through the gateway: `smoke-test-tools.sh`

```sh
sh utils/smoke-test-tools.sh https://<store>/skillhub <MCP_KEY_NN>
```

Calls the chat tools as that agent (the two file tools need a file; see below), through Kong, exactly as a client would. The nine
reading tools must answer; the writing tools write a note, a skill, a document record and a
structure request, and the test then **retires** the first three — that is the retire test,
and it also means the run leaves nothing behind that search will find.

Expect: `All tools answered.` and three `ok    skillhub_retire` lines.

One row stays: the structure request, `open`. Agents cannot close requests; the caretaker does,
and the test prints the call. That is the design working, not litter. Pass a table name as the
third argument to exercise `add_rows` as well.

Why it exists: four tools once shipped broken — each failed on every call it ever received
because a parameter shared a name with a column — and stayed broken for days, because agents
had another door. A broken door goes unnoticed for exactly as long as the door is optional.

## 4. The protocol, both eras: `test-mcp-protocol.py`

```sh
python3 utils/test-mcp-protocol.py https://<store>/skillhub --apikey <MCP_KEY_NN>
```

Fourteen checks. The legacy `initialize` handshake still answers; `server/discover` — the one
method the 2026-07-28 revision says a server MUST implement — answers with the supported
versions; every result carries `resultType` and the server's identity; `tools/list` carries its
cache hints; an unknown version gets `-32022` with the supported list, and a modern request
missing its client capabilities gets `-32602`, both as HTTP 400 so a client can tell a modern
server from a legacy one. A spoofed identity in the arguments is still overwritten on the
modern path.

Expect: `PASS -- 0 failing check(s)`.

Behind a Cloudflare tunnel the script identifies itself with a User-Agent, because the edge
answers HTTP 403 `error code: 1010` to Python's default one before the request reaches the
gateway. Eleven of fourteen checks failed that way once, on a server that was fine.

## 5. What a real client does: `probe-mcp-era.py`

Number 4 proves the server. This proves the other half: that a client's own SDK, in its default
`auto` mode, actually adopts the modern revision rather than falling back. The fallback is
silent — every tool keeps working on the legacy path — so a server can look fine in every log
while no client is on the path it advertises. That was the state here until `server/discover`
existed.

It needs the `mcp` SDK, so run it where a client runs, for example inside a Hermes container:

```sh
U=https://<store>/skillhub K=<MCP_KEY_NN> /opt/hermes/.venv/bin/python utils/probe-mcp-era.py
```

Expect `discover_result set: True`, `initialize_result set: False`, and the negotiated version.

---

## 5b. A file of rows, without a language model in the path

The two file tools cannot be smoke-tested without a file, so this one is by hand, once.
Make a small CSV with a header and a key column, then as an agent:

```
skillhub_upload_url(filename, sha256sum of the file, description)   -> a curl line
<run the curl line from a shell; no key needed>
skillhub_request_structure(purpose, fields, natural_key, document_id, observations)
```

Then as the caretaker: `select platform.load_registered_file(<request_id>);` and, a few
seconds later, `select * from platform.deliveries order by at desc limit 1;`. Expect the
table built, one row per key, the observations as column comments, and the delivery with
the file's hash. A second `skillhub_load_file` of the same file into that table must report
`inserted 0, updated N` — that is next month's export, and it needs nobody.

## 5c. Changing the embedding model, in this order

A model with a different dimension means a different vector column, and the order is not
free: the same `EMBEDDING_*` variables are read by the indexer **and** by the query side of
`skillhub_similar`. Change them first and the indexer refuses to mix the old vectors with
the new model, so nothing new is indexed; meanwhile the query side asks the new model and
finds no vectors under its name, so search by meaning returns **nothing** — quietly, which is
worse than an error. (If the new model keeps the old one's *name* and changes dimension,
every similarity query raises `different vector dimensions` instead.) `skillhub_overview` →
`caretaker` says `broken` either way and names the fix.

So:

```sql
truncate platform.embeddings;      -- 1. first, while the old model is still configured
```

2. Set `EMBEDDING_URL`, `EMBEDDING_KEY` and `EMBEDDING_MODEL`, and deploy.
3. Run the indexer once — `POST $URL/embed?batch=100&probe=1` with the service key — or wait
   five minutes for the cron.
4. `skillhub_overview` → `index`: the new model, its dimension, `waiting: 0`,
   `last_truncated: 0`, `last_error: null`.

Between 1 and 3 keyword search is unaffected and search by meaning finds nothing. The other
order trades those few minutes for an error on every query.

## 5d. A document's own words

Give an agent a PDF and the same words as before. It should now upload the file **and** its
`pdftotext -layout` output with the two curl lines `skillhub_upload_url` gives, then
`skillhub_load_text`. Within seconds `skillhub_search` finds a phrase from a late page with
that passage as the excerpt, `skillhub_similar` names the page in `matched`, and
`skillhub_read(kind=document, pages="7-8")` returns those pages verbatim. Measured on a
ten-page quality manual: 25,339 characters loaded, 14 chunks headed by page, a Swedish
question about supplier audits answered with page 8. The condensed skill the agent publishes
is still the curated layer; this is what it was condensed from, and what an auditor opens.

## 5e. A department's own rows

As the caretaker, give two agents the same word in `public.agents.team` and leave a third
without one. Ask the first to write a note "for the team". `skillhub_whoami` on the second
names the team and `skillhub_read`, `skillhub_search`, `skillhub_query` and
`skillhub_activity` all show the note; on the third none of them do, and `skillhub_similar`
never does for anyone, because team rows are not indexed by meaning. Ask the third to write a
team note: refused in words, not stored. `utils/test-seed-on-empty-db.sh` runs this whole
sequence on a fresh database. A team is a word: the caretaker's typo is the only way to get
it wrong, and the caveats say so.

## 6. Ask an agent something you know the answer to

Scripts prove the mechanism. Only an agent proves the store is usable, and the useful test is
a question whose correct answer depends on a rule written down in the store — because the
wrong answer arrives as a confident number, not as an error.

The pattern, with the data this project used: a quality register where sixteen rows out of
5,812 carry sentinel values in the quantity column. The rule saying so is in the column's
comment and in a published skill. Ask, with no hints:

> *How many individual defects were reported in total?*

An agent that searches the store before it computes answers **28,638**. One that goes straight
to the data answers **1,091,957** — thirty-eight times too high, stated with confidence. Same
tools, same data; the difference is whether it looked. That single number is a regression test
for the whole retrieval layer: search across column comments, the fallback to meaning when no
word matches, and the operating rules the agent reads at the start of a session.

For your own data, construct the equivalent: one rule that changes an answer, written into a
column comment or a skill, and one question that only comes out right if the rule was read.

Two more worth asking once, because each exercises a wall:

- **Hand an agent a document and ask it to put it in the store.** It should register the file
  *and* publish the content, keeping the document's own section numbers, and it should not
  present condensed text in quotation marks. An agent that registers the file and reports that
  a person must upload it has hit a rule that was wrong here once and is fixed; if you see it,
  the rule it read is stale.
- **Ask a colleague's agent to overwrite the first agent's skill.** It must be refused with the
  owner's name and the next version number to use, and publishing that next version must leave
  the original in place, marked superseded.

---

## 7. What fills the store, and when it stops

    select table_name, source_system, last_loaded, typical_gap, quiet from platform.v_sources;

One row per feed. Load the same export three times through `skillhub_load_file` and
`typical_gap` appears without anything being configured; let the next one slip past twice that
gap and `quiet` turns true and `skillhub_overview` grows a `feeds` line naming it. Two source
systems into one table are two rows. A table loaded once or twice has no rhythm, is never
reported quiet, and produces no line at all -- verified on a fresh database, because a
one-off import reported as an overdue feed is the noise that makes an operating surface
worthless. The state is `attention`, never `broken`: `utils/health.sh` must not exit 1 because
somebody's cron job stopped.

Load with `visibility=team` and the rows are the department's: `skillhub_query` counts them
for a team-mate and not for an outsider. The caretaker cannot load team rows of its own and is
told why -- a row reaches a team through its owner.

## When something fails

- `FAILED` in the seed log → the store is incomplete; fix the file, re-run `utils/seed.sh`.
- Drift check shows in-place edits → copy them into the working checkout, commit, push, deploy.
  Do not press Deploy first: that is how they disappear.
- A key answers 401 → Kong renders its list of permitted callers when the container is
  *created*. A key added after the first deploy needs Kong recreated, not restarted.
- Semantic search reports it is off, or new content takes five minutes to become findable →
  `EMBEDDING_URL` and `EMBEDDING_KEY` are empty. They are on purpose; set them.
- A retired or newly private object still turns up in `skillhub_similar` → the store is
  running SQL older than 2026-09-16. Re-seed; `select public.embed_prune();` clears what is
  already there, and the query side filters regardless.
- `index.last_truncated` is above zero → chunks were CUT at the model's input limit and that
  content is indexed in part, silently. Set `EMBEDDING_MAX_CHARS` below `max_chars_per_chunk`
  and run the indexer again.
- `skillhub_overview` → `index.meaning_search` is `error` → `last_error` names the object
  and the endpoint's answer. A wrong chunk size: set `EMBEDDING_MAX_CHARS`. A dimension the
  table cannot take because it holds vectors: `truncate platform.embeddings;` and re-run.
- HTTP 403 `error code: 1010` → the edge rejected your User-Agent before the gateway saw the
  request. Send one.
- An agent reports fewer tools than `tools/list` returns, or an old parameter set → it is
  holding the list it fetched when its gateway started. Restart the agent; the server is fine.
