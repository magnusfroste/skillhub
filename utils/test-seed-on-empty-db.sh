#!/bin/sh
# The receipt: an empty database plus this repo gives a working data store.
#
#   sh utils/test-seed-on-empty-db.sh
#
# Raises a throwaway Postgres from the same image the stack uses, seeds it, seeds it AGAIN
# (utils/seed.sh runs on every boot, so a second run has to be a no-op), and then checks that
# the store actually answers -- not just that no statement raised.
#
# Written 2026-09-14, and the first run of it found five things that a fresh deploy would have
# hit and nobody had, because every previous apply had been against a database where the
# objects already existed:
#   * conventions.sql needed auth.jwt(), which GoTrue brings up, not the database
#   * two views selected from objects defined further down the same file
#   * notes and documents were missing retired_at/_by/_reason -- three columns each that
#     existed in production and in no file, so skillhub_retire would have failed outright
#   * the conventions skill was inserted in a way that produced a duplicate row on re-run
#   * create_shared_table refused a table that already existed, so the seed could run once
#     and never again
# None of that is visible by reading. Run this before trusting a deploy.
set -eu

IMAGE="${IMAGE:-supabase/postgres:17.6.1.136}"
NAME="${NAME:-seedtest-$$}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# KEEP=1 leaves the container running for a look with: docker exec -it $NAME psql -U postgres
cleanup() { [ -n "${KEEP:-}" ] && { echo "   kept: $NAME"; return; }; docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup

echo "1. empty database from $IMAGE"
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=seedtest -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null
# Wait for a STABLE database, not the first "ready". The Supabase image initialises, then
# restarts itself once; pg_isready answers during the first window, the seed starts, and
# the server goes away under it with "the database system is starting up". Measured
# 2026-09-14 after three clean passes -- a race, not a regression. So: ready on five
# consecutive checks a second apart, and a real query has to succeed.
n=0; stable=0
until [ $stable -ge 5 ] || [ $n -ge 120 ]; do
  if docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 \
     && docker exec "$NAME" psql -U postgres -At -c 'select 1' >/dev/null 2>&1; then stable=$((stable+1)); else stable=0; fi
  sleep 1; n=$((n+1))
done
[ $stable -ge 5 ] || { echo "   database never became stably ready"; exit 1; }
echo "   ready and stable (${n}s)"

# client_min_messages: a NOTICE ("index does not exist, skipping") is printed before the
# answer, and head -1 then reads the notice instead of the result.
q() { docker exec -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -At -c "$1"; }

echo "2. first seed"
DB_CONTAINER="$NAME" DB_USER=postgres sh "$REPO/utils/seed.sh" | sed 's/^/   /'

echo "3. second seed -- must be a no-op, because it runs on every boot"
DB_CONTAINER="$NAME" DB_USER=postgres sh "$REPO/utils/seed.sh" | sed 's/^/   /'

echo "4. does the store answer?"
fail=0
check() { # label, sql, expectation
  got="$(q "$2" 2>&1 | head -1)"
  if [ "$got" = "$3" ]; then printf "   %-46s %s\n" "$1" "ok"
  else printf "   %-46s GOT '%s' WANTED '%s'\n" "$1" "$got" "$3"; fail=1; fi
}
check "tables follow the convention" \
  "select count(*) from platform.v_catalog where follows_convention" "3"
check "the agent slots are seeded" \
  "select count(*) from public.agents" "11"
check "the onboarding steps are there" \
  "select count(*) from public.start_here" "9"
check "the index-on-write trigger is installed" \
  "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='platform' and p.proname='nudge_embed'" "1"
# Sixteen SQL functions behind seventeen tools: skillhub_upload_url and skillhub_load_file
# live in the edge function (they talk to Storage), and skillhub_load_rows is SQL with no
# tool of its own -- the loader calls it. Counting SQL, not tools, is what this database
# receipt can verify.
# skillhub_load_text, like upload_url and load_file, lives in the MCP server: twenty here.
check "every skillhub_ function the gateway offers exists" \
  "select count(distinct proname) from pg_proc where proname like 'skillhub\\_%'" "21"
check "rules are readable" \
  "select (public.skillhub_rules() ? 'placement_rule')::text" "true"
check "overview answers" \
  "select (public.skillhub_overview() is not null)::text" "true"
check "the conventions skill is there, once" \
  "select count(*) from public.skill_library where slug='store-conventions'" "1"
check "and its appended sections appear once after two seed runs" \
  "select (length(skill_md)-length(replace(skill_md,'## Overview','')))/11 || ':' || (length(skill_md)-length(replace(skill_md,'## House standards','')))/18 || ':' || (length(skill_md)-length(replace(skill_md,'## Lifecycle and files','')))/22 || ':' || (length(skill_md) < 30000)::text from public.skill_library where slug='store-conventions'" "1:1:1:true"
check "soft delete columns exist on notes" \
  "select count(*) from information_schema.columns where table_schema='public' and table_name='notes' and column_name in ('retired_at','retired_by','retired_reason')" "3"
check "a write through the tool tier works" \
  "select (public.skillhub_write_note('agent_01','Seed test','Written by the empty-database test to prove the tool tier works on a fresh install.') ? 'id')::text" "true"
check "and it is attributed to the caller" \
  "select owner from public.notes where title='Seed test'" "agent_01"
check "the change log caught it" \
  "select count(*) from platform.events where table_name='notes' and operation='insert'" "1"
# Retirement, end to end, because a caller/function signature mismatch here shipped once:
# skillhub_retire passed four arguments to a retire_skill that a fresh install created with
# three. Every retirement failed on a virgin instance and this test passed, since it never
# retired anything. publish requires a prior search, so search first.
check "a search then a publish through the gate works" \
  "select (public.skillhub_search('seed test skill', 10, 'agent_01') is not null)::text || ':' || (public.skillhub_publish_skill('agent_01','seed-test-skill','Seed test','A skill written by the empty-database test to prove the publish gate and skill retirement work on a fresh install. It carries no procedure and is retired by the same test a moment later, which is the point: retirement has to work from nothing.','test') ? 'slug')::text" "true:true"
check "retiring that skill works (the four-argument retire_skill exists)" \
  "select (public.skillhub_retire('agent_01','skill','seed-test-skill','seed test cleanup') ? 'retired_by')::text" "true"
check "and it is deprecated, not deleted" \
  "select status from public.skill_library where slug='seed-test-skill'" "deprecated"
# Two published versions of one slug -- the normal outcome of a colleague improving a
# skill -- once broke similarity search, duplicated keyword hits and made the indexer
# re-embed the slug forever. All three read platform.v_current_skills now; this pins it.
check "a second version of a skill can be published" \
  "select (public.skillhub_publish_skill('agent_01','seed-two-versions','Two versions','A probe skill with two published versions, written by the empty-database test to pin the one-row-per-slug rule: keyword search must return a slug once, the indexer must see only the newest version, and similarity search must not fail when a slug has more than one published version. It carries no procedure and is retired by the test.','p') ? 'slug')::text || ':' || (public.skillhub_publish_skill('agent_01','seed-two-versions','Two versions','A probe skill with two published versions, written by the empty-database test to pin the one-row-per-slug rule: keyword search must return a slug once, the indexer must see only the newest version, and similarity search must not fail when a slug has more than one published version. It carries no procedure and is retired by the test. Improved.','p','{}','1.1.0') ? 'slug')::text" "true:true"
check "keyword search returns that slug once" \
  "select count(*) from platform.search('seed-two-versions', 10) where id='seed-two-versions'" "1"
check "the indexer sees that slug once, and the newest version" \
  "select count(*)::text||':'||bool_or(c->>'text' like '%Improved.%')::text from jsonb_array_elements(public.embed_candidates(1000)) c where c->>'id'='seed-two-versions'" "1:true"
q "insert into platform.embeddings(source,id,model,vector,text_hash) values ('skill','seed-two-versions','probe',array_fill(0::real,array[1536])::vector(1536),'x')" >/dev/null
check "similarity does not fail on a slug with two versions" \
  "select (public.skillhub_similar(to_jsonb(array_fill(0::real,array[1536])),'probe',3) is not null)::text" "true"
# A document registered without a path -- the normal case, the file lives where it lives --
# once failed on every call: bucket is NOT NULL with a default, and the function passed an
# explicit null. Found on the demo 2026-09-15, two attempts, by an agent doing it right.
check "a document is registered without a path" \
  "select (public.skillhub_register_document('agent_01','seed-test.csv',7509,'text/csv','0000seed','Written by the empty-database test','laptop') ? 'id')::text" "true"
check "and it landed in the shared bucket" \
  "select bucket from public.documents where sha256='0000seed'" "shared"
check "the loading house standard is at 1.1.0 and the agent path" \
  "select version || ':' || (skill_md like '%skillhub_upload_url%')::text from platform.v_current_skills where slug='load-from-source-system'" "1.1.0:true"
# Chunking (2026-09-16): a long text is cut on its headings, each chunk carries the title,
# the object is saved as several vectors and comes back from similarity ONCE, naming the
# section that matched. An embedder built for RAG (512-2048 tokens) needs exactly this.
# The pointer names the first AND last heading the chunk holds: one alone sent a reader
# asking about section 7.3 to the heading the chunk began at, 3.4 (2026-09-17).
check "the pointer names the range of headings a chunk covers" \
  "select head from platform.chunk_text('T', '## One'||E'\n'||repeat('a ',300)||E'\n\n## Two'||E'\n'||repeat('b ',300)||E'\n\n## Three'||E'\n'||repeat('c ',300), 4000) limit 1" "## One  ...  ## Three"
check "a chunk cut from the middle of a long section carries its heading forward" \
  "select head from platform.chunk_text('T', '## Page 4'||E'\n'||repeat('word ',900)||E'\n\n'||repeat('more ',900), 2500) where chunk = 1" "## Page 4 (continued)"
# A note whose line breaks were lost in transit is not one enormous heading (2026-09-21).
# Measured on a client install: an agent flattened a 5 KB markdown note to a single line to get
# it past its own client's JSON building, and every chunk of it then carried the same 120
# characters of prose as its pointer.
check "the conventions say long text is handed over as a file, not squeezed through an argument" \
  "select (skill_md like '%Long text goes as a file%')::text || ':' || (skill_md like '%skillhub_load_text(document_id)%')::text from platform.v_current_skills where slug='store-conventions'" "true:true"
check "prose that merely starts with a hash is not a heading" \
  "select platform.is_heading('## Arkitektur')::text || ':' || platform.is_heading('## Vad systemet är Marknadsledande ERP för tillverkande industri. ## Arkitektur G4 ar aldre, G5 ar nuvarande.')::text || ':' || platform.is_heading(repeat('x', 200))::text" "true:false:false"
check "and no chunk of a flattened note claims a heading holding two of them" \
  "select (count(*) filter (where head ~ '#{1,6} .*[[:space:]]#{1,6} '))::text || ':' || (count(distinct head) > 1)::text from (select repeat('alfa ', 90) as a, repeat('beta ', 90) as b) s, lateral platform.chunk_text('Flattened probe', '## Ett ' || s.a || ' ## Tva ' || s.b, 400)" "0:true"
check "a single-heading chunk names just that one" \
  "select head from platform.chunk_text('T', '## Only'||E'\n'||repeat('a ',100), 4000) limit 1" "## Only"
check "a long text is chunked on its headings, title on every chunk" \
  "select count(*)::text || ':' || bool_and(content like 'Title%')::text || ':' || max(head) from platform.chunk_text('Title', '## One'||E'\n'||repeat('a ',900)||E'\n\n## Two'||E'\n'||repeat('b ',900)||E'\n\n## Three'||E'\n'||repeat('c ',900), 2500)" "3:true:## Two"
check "a short text stays one chunk" \
  "select count(*) from platform.chunk_text('Title', 'A short body.', 2500)" "1"
check "the candidates carry chunks when the budget is small" \
  "select count(*) > 1 from jsonb_array_elements(public.embed_candidates(1000, 600)) c where c->>'source'='skill' and c->>'id'='store-conventions'" "t"
q "select public.embed_save_chunks('skill','seed-two-versions','probe', jsonb_build_array(to_jsonb(array_fill(0::real,array[1536])), to_jsonb(array_fill(0::real,array[1536]))), '[\"## A\",\"## B\"]'::jsonb, 'x')" >/dev/null
check "two chunks saved, and similarity returns the object once with its section" \
  "select (select count(*) from platform.embeddings where id='seed-two-versions')::text || ':' || (select count(*) from jsonb_array_elements(public.skillhub_similar(to_jsonb(array_fill(0::real,array[1536])),'probe',10)) h where h->>'id'='seed-two-versions')::text || ':' || (select h->'matched'->>'of' from jsonb_array_elements(public.skillhub_similar(to_jsonb(array_fill(0::real,array[1536])),'probe',10)) h where h->>'id'='seed-two-versions')" "2:1:2"
check "the overview shows the index status" \
  "select (public.skillhub_overview()->'index'->>'meaning_search') || ':' || (public.skillhub_overview()->'index'->>'chunks')" "off:2"
q "truncate platform.embeddings" >/dev/null
check "the dimension can be changed by function while the table is empty" \
  "select left(platform.set_vector_dim(1024), 41)" "The vector store is now vector(1024) with"
check "and similar() follows the dimension" \
  "select count(*) from platform.similar(array_fill(0::real,array[1024])::vector, 'probe', 3)" "0"

# What a virgin instance does on a model that is not 1,536-dimensional -- the client's is
# 4,096 (Qwen3-Embedding-8B). The seed builds the table at 1,536 with an HNSW index; the
# indexer's first run probes, calls set_vector_dim, and everything downstream has to follow,
# INCLUDING the next boot's seed. platform.sql created that index unconditionally until
# 2026-09-16 and the seed then failed on the first file, skipping every file after it.
check "a fresh install moves to 4,096: no index, because HNSW stops at 4,000" \
  "select (platform.set_vector_dim(4096) like '%NO index%')::text || ':' || (to_regclass('platform.embeddings_vector_idx') is null)::text" "true:true"
DB_CONTAINER="$NAME" DB_USER=postgres sh "$REPO/utils/seed.sh" 2>&1 | grep -q FAILED \
  && { printf "   %-46s %s\n" "the seed runs again at 4,096 without failing" "FAILED -- see utils/seed.sh output"; fail=1; } \
  || printf "   %-46s %s\n" "the seed runs again at 4,096 without failing" "ok"
check "a 4,096 vector goes in and comes back out" \
  "select public.embed_save_chunks('schema','notes','probe', jsonb_build_array(to_jsonb(array_fill(0.01::real,array[4096]))), to_jsonb(array['x']), 'h') ? 'chunks'" "t"
check "and the tools answer at that dimension" \
  "select jsonb_array_length(public.skillhub_similar(to_jsonb(array_fill(0.01::real,array[4096])),'probe',5))::text || ':' || (public.skillhub_overview()->'index'->>'table_dimension')" "1:4096"
q "truncate platform.embeddings" >/dev/null
check "between 2,000 and 4,000 it is a half-precision index" \
  "select (platform.set_vector_dim(3072) like '%half-precision%')::text || ':' || (to_regclass('platform.embeddings_vector_idx') is not null)::text" "true:true"
check "and back down to 1,536 the ordinary index returns" \
  "select (platform.set_vector_dim(1536) like '%with an HNSW index%')::text || ':' || (to_regclass('platform.embeddings_vector_idx') is not null)::text" "true:true"
# Rebuilding the index is the caretaker's one legitimate delete, and it has to say why --
# the sentence goes in the change log, because "search went quiet for ten minutes" needs an
# answer later. Written 2026-09-16 after doing the same thing by hand in the wrong order.
check "a reindex without a reason is refused" \
  "select coalesce((select 'built' from (select platform.reindex('oops')) z), '')" "ERROR:  Say why you are rebuilding the index. A model change is exactly the kind of event this store exists to make traceable, and the sentence goes in the change log for whoever asks later why search went quiet for ten minutes."
q "select public.embed_save_chunks('note','reindex-probe','probe', jsonb_build_array(to_jsonb(array_fill(0::real,array[1536]))), '[\"x\"]'::jsonb, 'h')" >/dev/null
q "select platform.reindex('switching to the private model for the demo', 'service_role')" >/dev/null
check "a reindex with a reason empties the index and logs it" \
  "select (select count(*) from platform.embeddings)::text || ':' || (select count(*) from platform.events where table_name='platform.embeddings' and summary like '%switching to the private model%')::text" "0:1"
# The log line names what was DISCARDED, read off the vectors -- not the model last probed,
# which after a model change is the new one.
check "the log names the model the discarded vectors came from" \
  "select (summary like '%model probe at dimension 1536%')::text from platform.events where table_name='platform.embeddings' order by at desc limit 1" "true"
# An agent could not see what became of its own structure request: on the demo 2026-09-16
# agent_04 filed one, saw it still open, and concluded the delivery was done and waiting.
# Write and read in separate statements -- skillhub_overview is STABLE and reads the
# snapshot the statement began with, so a request created in the same SELECT is not there.
q "select public.skillhub_request_structure('agent_01','A probe request written by the empty-database test to pin that an agent can see what became of it', to_jsonb(array['a','b']))" >/dev/null
check "an agent sees its own request, and it is open" \
  "select jsonb_array_length(public.skillhub_overview('agent_01')->'your_requests')::text || ':' || (public.skillhub_overview('agent_01')->'your_requests'->0->>'status')" "1:open"
check "and another agent does not see it as theirs" \
  "select jsonb_array_length(public.skillhub_overview('agent_02')->'your_requests')::text" "0"
q "select platform.resolve_structure_request((select max(id) from platform.structure_requests), 'service_role', 'Loaded from the uploaded file instead; nothing for you to do.', null, true)" >/dev/null
check "the caretaker's answer reaches the agent" \
  "select (public.skillhub_overview('agent_01')->'your_requests'->0->>'status') || ':' || left(public.skillhub_overview('agent_01')->'your_requests'->0->>'answer', 24)" "declined:Loaded from the uploaded"
# A vector outlives its object's visibility: retiring took an object out of keyword search
# but left it findable by meaning, and a note flipped to private kept the vector it had
# while it was public. Found 2026-09-16 when a rebuild came back six objects lighter.
q "select public.skillhub_write_note('agent_01','Vector visibility probe','A public note written by the empty-database test, retired a moment later to pin that a retired object stops being findable by meaning.')" >/dev/null
q "select public.embed_save_chunks('note', (select id::text from public.notes where title='Vector visibility probe'), 'probe', jsonb_build_array(to_jsonb(array_fill(0::real,array[1536]))), to_jsonb(array['x']), 'h')" >/dev/null
# One indexing pass at a time (2026-09-22): three callers, no lock, and on a client install two
# overlapping passes embedded the same document and collided on its key six runs in a row.
check "the first pass claims the index, the second is refused" \
  "select public.index_run_begin()::text || ':' || public.index_run_begin()::text" "true:false"
check "and after it ends, the next one is admitted" \
  "select (select public.index_run_end()) is null, public.index_run_begin()" "t|t"
q "update platform.embedder set running_since = now() - interval '11 minutes'" >/dev/null
check "a pass that died holding the lock is overridden after ten minutes" \
  "select public.index_run_begin()::text" "true"
q "select public.index_run_end()" >/dev/null
# Written and read in separate statements: a read in the same SELECT as the write sees the
# statement's opening snapshot and returns nothing -- the trap that has bitten four tests here.
DIM="(select atttypmod from pg_attribute where attrelid='platform.embeddings'::regclass and attname='vector')"
q "select public.embed_save_chunks('note','probe-race','m', jsonb_build_array(to_jsonb(array_fill(0.1::real, array[$DIM]))), '[\"h\"]'::jsonb, 'abc', 2000)" >/dev/null
q "select public.embed_save_chunks('note','probe-race','m', jsonb_build_array(to_jsonb(array_fill(0.2::real, array[$DIM]))), '[\"h2\"]'::jsonb, 'abc', 2000)" >/dev/null
check "saving the same object twice is harmless, not a duplicate key" \
  "select count(*)::text || ':' || max(head) from platform.embeddings where id='probe-race'" "1:h2"
q "delete from platform.embeddings where id='probe-race'" >/dev/null
check "a public note is returned by meaning" \
  "select count(*) from jsonb_array_elements(public.skillhub_similar(to_jsonb(array_fill(0::real,array[1536])),'probe',20)) h where h->>'title'='Vector visibility probe'" "1"
q "select public.skillhub_retire('agent_01','note',(select id::text from public.notes where title='Vector visibility probe'),'pinning that a retired object leaves the meaning index too')" >/dev/null
check "and after retiring it is not, though the vector is still there" \
  "select (select count(*) from jsonb_array_elements(public.skillhub_similar(to_jsonb(array_fill(0::real,array[1536])),'probe',20)) h where h->>'title'='Vector visibility probe')::text || ':' || (select count(*) from platform.embeddings where model='probe' and source='note')::text" "0:1"
check "the prune removes it" \
  "select public.embed_prune() >= 1" "t"
check "and then the vector is gone" \
  "select count(*) from platform.embeddings where model='probe' and source='note'" "0"
# The caretaker's operating surface: one call that says ok, attention or broken, with the
# call to fix each thing. Everything it reads had a view a day earlier; what was missing was
# anything that ASKED, which is why every fault on 2026-09-16 was found by happening to look.
check "health answers, and says what is waiting" \
  "select (platform.health() ? 'verdict')::text || ':' || (platform.health() ? 'checks')::text || ':' || (jsonb_array_length(platform.health()->'checks') >= 4)::text" "true:true:true"
check "a store with no backup and no embedder wants attention, not alarm" \
  "select platform.health()->>'verdict'" "attention"
check "every check that wants something carries the call that does it" \
  "select bool_and((c->>'run') is not null) from jsonb_array_elements(platform.health()->'checks') c where c->>'state' <> 'ok'" "t"
# An agent handed a list works through it. So the safe calls and the ones that change
# something are separate keys, and only the safe ones are a list.
check "what only looks is a list; what changes is a decision" \
  "select (jsonb_array_length(platform.health()->'look') > 0)::text || ':' || bool_and((d->>'changes') is not null)::text from jsonb_array_elements(platform.health()->'decide') d" "true:true"
check "the caretaker sees it inside the tool every agent runs" \
  "select (public.skillhub_overview('service_role')->'caretaker' ? 'verdict')::text || ':' || (public.skillhub_overview('agent_01')->>'caretaker' is null)::text" "true:true"
q "select public.index_run_save(jsonb_build_object('model','probe','dimension',1536,'objects',3,'embedded',3,'chunks',4,'truncated',0,'failed',0,'requests',1,'pruned',0,'seconds',0.4,'tokens',4200))" >/dev/null
check "what the index cost is remembered too" \
  "select (select tokens from platform.index_runs order by at desc limit 1)::text || ':' || (select (platform.health()->'checks') @> '[{\"check\":\"embedding tokens\"}]')::text" "4200:true"
check "a run is remembered, so flapping is answerable" \
  "select count(*)::text || ':' || (platform.health()->'checks' @> '[{\"check\":\"indexing, last 24h\"}]')::text from platform.index_runs" "1:true"
q "select public.backup_record('content','/root/.skillhub-backups/probe',1024,'written by the empty-database test')" >/dev/null
q "select platform.set_retention('disposable','a throwaway probe database, rebuilt from the repository on every test run')" >/dev/null
# A store that nobody keeps should not be asked for backups: a check that fires on a decision
# somebody made on purpose is how a person learns to stop reading the list.
check "a disposable store is not asked for a backup, and says why" \
  "select (select c->>'state' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='backup') || ':' || (select (c->>'detail') like '%declared disposable%rebuilt from the repository%' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='backup')::text" "ok:true"
check "and a reason is required to declare it" \
  "select coalesce((select 'set' from (select platform.set_retention('disposable','no')) z), '')" "ERROR:  Say why, in a sentence. Somebody will read this the day they look for a backup that was never taken."
# Separate statements: platform.health() is STABLE and reads the snapshot its statement began
# with, so a declaration changed in the same SELECT is not visible to it -- the same trap the
# register_document and overview checks hit.
check "declaring it kept answers in words" \
  "select (platform.set_retention('kept','this probe instance is kept so the test can see the question return') like 'This store is declared kept%')::text" "true"
check "and the sentence about nobody expecting a backup is gone" \
  "select (select (c->>'detail') like '%declared disposable%' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='backup')::text" "false"
q "delete from platform.retention" >/dev/null
check "a recorded backup turns that check green" \
  "select c->>'state' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='backup'" "ok"
# Boots are not activity. The seed re-applies the house on every boot; until 2026-09-16 each
# re-application was logged, and 223 of 242 writes in a day were the store telling itself
# what it already knew. The caretaker flagged it as a write loop.
q "select count(*) from platform.events" > /tmp/.events_before_$$ 2>/dev/null || true
BEFORE="$(q "select count(*) from platform.events")"
DB_CONTAINER="$NAME" DB_USER=postgres sh "$REPO/utils/seed.sh" >/dev/null 2>&1
check "a boot over an up-to-date store writes nothing to the change log" \
  "select count(*) - $BEFORE from platform.events" "0"
check "but the boot itself is recorded, with every file ok" \
  "select (count(*) >= 3)::text || ':' || (select failed_file is null from platform.seed_runs order by at desc limit 1)::text from platform.seed_runs" "true:true"
check "and health says so" \
  "select c->>'state' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='store'" "ok"
q "insert into platform.seed_runs (ok, failed_file, error) values (2, 'platform.sql', 'ERROR: column cannot have more than 2000 dimensions for hnsw index')" >/dev/null
check "a failed boot is broken, naming the file" \
  "select (platform.health()->>'verdict') || ':' || (select c->>'state' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='store') || ':' || (select (c->>'detail') like '%stopped at platform.sql%' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='store')::text" "broken:broken:true"
q "delete from platform.seed_runs where failed_file = 'platform.sql'" >/dev/null
# The shape of a similarity search decides whether an index can serve it. Grouping chunks
# into objects inside the ordered scan kept HNSW from being used at all and made a search
# over 25,000 chunks at 4,096 dimensions take 28 seconds (2026-09-16). Stage one must be a
# bare ORDER BY distance LIMIT k, written in the expression the index was built on.
# enable_sort=off asks "can the index serve this ORDER BY": the vector index is the only path
# that returns rows already in distance order, so if the query is in a shape it can serve,
# the planner takes it; if not, the plan shows a Sort. (enable_seqscan=off alone does not
# ask that -- on a table this small the planner answers with a bitmap scan on the primary
# key and a sort, which is how the first version of this check failed a query that was fine.)
plan() { docker exec -e PGOPTIONS="-c enable_seqscan=off -c enable_sort=off -c client_min_messages=warning" "$NAME" psql -U postgres -At -c "explain (costs off) select * from platform.similar(array_fill(0.1::real, array[$1])::vector, 'probe', 100)" 2>&1; }
planned() { if plan "$1" | grep -q "Index Scan using embeddings_vector_idx"; then echo yes; else echo no; fi; }
q "truncate platform.embeddings" >/dev/null
q "select platform.set_vector_dim(1536)" >/dev/null
printf "   %-46s %s\n" "a similarity search can use the HNSW index" "$( [ "$(planned 1536)" = yes ] && echo ok || { echo "FAILED -- $(plan 1536 | head -3 | tr '\n' ' ')"; } )"
[ "$(planned 1536)" = yes ] || fail=1
q "select platform.set_vector_dim(3072)" >/dev/null
printf "   %-46s %s\n" "and the half-precision one at 3,072" "$( [ "$(planned 3072)" = yes ] && echo ok || { echo "FAILED -- $(plan 3072 | head -3 | tr '\n' ' ')"; } )"
[ "$(planned 3072)" = yes ] || fail=1
q "select platform.set_vector_dim(1536)" >/dev/null
# A changed chunk size re-embeds nothing -- the text did not change -- so the index stays cut
# the old way and nothing says so. Health has to. A quarter either way, so a small drift is quiet.
q "truncate platform.embeddings" >/dev/null
q "select public.embedder_save(jsonb_build_object('url','http://probe','model','probe','dimension',1536,'max_chars',6700,'limit_source','env','status','ok'))" >/dev/null
q "select public.embed_save_chunks('schema','notes','probe', jsonb_build_array(to_jsonb(array_fill(0.1::real,array[1536]))), to_jsonb(array['x']), 'h', 21600)" >/dev/null
check "an index cut at another chunk size is reported, with the rebuild as a decision" \
  "select (select c->>'state' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='chunk size') || ':' || (select count(*) from jsonb_array_elements(platform.health()->'decide') d where d->>'call' like '%platform.reindex(%chunk size changed from 21600 to 6700%')::text" "attention:1"
q "select public.embed_save_chunks('schema','notes','probe', jsonb_build_array(to_jsonb(array_fill(0.1::real,array[1536]))), to_jsonb(array['x']), 'h', 6900)" >/dev/null
check "and a drift inside a quarter is not" \
  "select count(*) from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='chunk size'" "0"
q "select public.embed_save_chunks('schema','notes','probe', jsonb_build_array(to_jsonb(array_fill(0.1::real,array[1536]))), to_jsonb(array['x']), 'h')" >/dev/null
check "a vector whose chunk size was never recorded asks for one rebuild, not a guess" \
  "select (select c->>'state' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='chunk size') || ':' || (select count(*) from jsonb_array_elements(platform.health()->'decide') d where d->>'call' like '%recording the chunk size%')::text" "attention:1"
q "truncate platform.embeddings; delete from platform.embedder" >/dev/null
# The noticeboard (DECISIONS 26). Nothing here is notified: the value is that the note stays
# up, and that an answer which was not already in the store becomes one.
check "a question too short to answer is refused" \
  "select coalesce((select 'posted' from (select public.skillhub_ask('agent_01','where is it')) z), '')" "ERROR:  Ask enough that a colleague can answer without asking you back: what you need, and what you already looked at."
check "a question addressed to nobody in particular is posted, with what the store already holds" \
  "select (public.skillhub_ask('agent_01','Does anyone know which column of the ticket export holds the real hours, and what 999 means there?') ? 'already_in_the_store')::text" "true"
check "and addressing it to an agent that does not exist is refused" \
  "select coalesce((select 'posted' from (select public.skillhub_ask('agent_01','A perfectly reasonable question addressed to nobody real at all','agent_99')) z), '')" "ERROR:  No agent \"agent_99\". skillhub_overview lists who is here; leave for_agent out to ask whoever knows."
q "select public.skillhub_ask('agent_01','Where did the supplier audit register end up, and who loaded it?','agent_02')" >/dev/null
check "the agent it was addressed to sees it, and nobody else does" \
  "select jsonb_array_length(public.skillhub_overview('agent_02')->'questions'->'asked_of_you')::text || ':' || jsonb_array_length(public.skillhub_overview('agent_03')->'questions'->'asked_of_you')::text" "1:0"
check "a question open to anyone is offered to a colleague, not to its author" \
  "select jsonb_array_length(public.skillhub_overview('agent_03')->'questions'->'open_to_anyone')::text || ':' || jsonb_array_length(public.skillhub_overview('agent_01')->'questions'->'open_to_anyone')::text" "1:0"
q "select public.skillhub_answer('agent_02', (select max(id) from platform.asks), 'It is in public.support_tickets; hours_spent 999 means the time was never recorded, so exclude it from sums.')" >/dev/null
check "the answer reaches the asker, and the question is no longer open" \
  "select (public.skillhub_overview('agent_01')->'questions'->'your_questions'->0->>'status') || ':' || (public.skillhub_overview('agent_01')->'questions'->'your_questions'->0->'answers'->0->>'from')" "answered:agent_02"
check "answering tells you to write it down, which is the whole point" \
  "select (public.skillhub_answer('agent_03', (select min(id) from platform.asks), 'Column hours_spent, and 999 is a sentinel for not recorded.')->>'next_step' like '%WRITE IT DOWN%')::text" "true"
q "select public.skillhub_ask('agent_03','Has anybody worked out where the old audit spreadsheets are kept these days?')" >/dev/null
check "health notices a question nobody has answered" \
  "select ((platform.health()->'checks') @> '[{\"check\":\"questions on the board\"}]')::text" "true"
# One integer and the rest defaulted is how a caretaker calls this. Two earlier signatures
# lived on dev and made that call ambiguous (2026-09-17); the seed drops them now.
check "the caretaker has exactly one load_registered_file to call" \
  "select count(*) from pg_proc where proname='load_registered_file' and pronamespace='platform'::regnamespace" "1"
# The conventions skill is now published from its sections as a NEW VERSION when the text
# changes, never edited in place: it was the one house document with no earlier version to
# show anyone, while every skill an agent publishes has kept all of them since the beginning.
check "the conventions skill is assembled from its sections" \
  "select (count(*) >= 5)::text || ':' || (min(ord) = 0)::text from platform.convention_sections" "true:true"
check "and published as a version, with the sections in it" \
  "select version || ':' || (skill_md like '%PLACEMENT RULE%' and skill_md like '%## Lifecycle and files%' and skill_md like '%## House standards%' and skill_md like '%## Asking each other%')::text from platform.v_current_skills where slug='store-conventions'" "1.0.0:true"
q "select platform.put_conventions_section(90, 'a probe section', E'\n## A probe section\n\nWritten by the empty-database test to pin that a changed section publishes a new version.\n')" >/dev/null
check "a changed section publishes the next version and supersedes the last" \
  "select left(platform.assemble_conventions(), 33)" "store-conventions 1.1.0 published"
check "both versions are there, the older one marked" \
  "select count(*)::text || ':' || (select superseded_by from public.skill_library where slug='store-conventions' and version='1.0.0') from public.skill_library where slug='store-conventions'" "2:1.1.0"
check "an agent can read the older version by name" \
  "select (public.skillhub_read('skill','store-conventions',null,'1.0.0')->>'version') || ':' || (public.skillhub_read('skill','store-conventions',null,'1.0.0')->>'content' not like '%A probe section%')::text" "1.0.0:true"
check "and sees which versions exist without being told" \
  "select jsonb_array_length(public.skillhub_read('skill','store-conventions')->'versions')::text || ':' || (public.skillhub_read('skill','store-conventions')->>'version')" "2:1.1.0"
# The tools hand an agent a readable error rather than a raised one, so this is what it sees.
check "asking for a version that never existed says which do" \
  "select public.skillhub_read('skill','store-conventions',null,'9.9.9')->>'error'" "No version 9.9.9 of \"store-conventions\". The versions that exist: 1.0.0, 1.1.0."
q "delete from platform.convention_sections where ord = 90" >/dev/null
q "select platform.assemble_conventions()" >/dev/null
# The door onto start_here, which nothing read for the first fortnight -- and which told its
# only reader to run raw SQL, the one thing an agent key may not do.
check "help is plain text, names the steps in order, and lists the topics" \
  "select (public.skillhub_help() like '%WHAT TO DO, IN ORDER%')::text || ':' || (public.skillhub_help() like '%1. See the state%')::text || ':' || (public.skillhub_help() like '%load-from-source-system%')::text" "true:true:true"
check "and the steps name tools, not SQL an agent may not run" \
  "select (count(*) = 0)::text from public.start_here where do_this like '%select %' or do_this like '%platform.%'" "true"
# The invite the caretaker hands out and the file the host script fills must be the same text:
# two copies of an onboarding block drift into two rulebooks, so the build refuses to differ.
MD_BLOCK_MD5=$(sed -n '/skillhub:identity start/,/skillhub:identity end/p' utils/agent-invite.md | sed 's/^ *//; s/ *$//' | md5sum | cut -d' ' -f1)
check "the caretaker's invite skill carries the same SOUL block as the file" \
  "select md5(regexp_replace(regexp_replace(substring(skill_md from '<!-- skillhub:identity start -->.*<!-- skillhub:identity end -->'), '^ +', '', 'gn'), ' +$', '', 'gn') || E'\\n') from platform.v_current_skills where slug='inviting-an-agent'" "$MD_BLOCK_MD5"
check "and no longer explains a server a new agent has never had" \
  "select version || ':' || (skill_md not like '%One server, not two%')::text from platform.v_current_skills where slug='inviting-an-agent'" "1.1.0:true"
check "and leaves the key as a placeholder, never a value" \
  "select (skill_md like '%apikey: <KEY>%')::text || ':' || (skill_md !~ 'apikey: [0-9a-f]{20}')::text from platform.v_current_skills where slug='inviting-an-agent'" "true:true"
check "and help finds it by the word a person would use" \
  "select (public.skillhub_help('invite') like '%Pick a free slot%')::text" "true"
check "a topic reads the whole standard" \
  "select (public.skillhub_help('loading') like '%load-from-source-system%Load data from a source system%')::text || ':' || (length(public.skillhub_help('loading')) > 2000)::text" "true:true"
check "a topic that does not exist answers with the ones that do" \
  "select (public.skillhub_help('kaffe') like '%No topic matches \"kaffe\"%')::text || ':' || (public.skillhub_help('kaffe') like '%caretaker-operations%')::text" "true:true"
check "overview points at help instead of repeating the tour" \
  "select (public.skillhub_overview()->'read_this_first'->>0 like '%skillhub_help%')::text || ':' || jsonb_array_length(public.skillhub_overview()->'read_this_first')::text" "true:3"
# The store's only channel to an agent it did not install: the caretaker gets these rules seeded
# into its SOUL.md by a compose file, an agent on somebody's laptop gets a key and this call.
check "and carries the two rules a hand-configured agent has no other way of learning" \
  "select ((public.skillhub_overview()->'read_this_first'->>1) like '%RESEARCH anything from scratch%')::text || ':' || ((public.skillhub_overview()->'read_this_first'->>2) like '%not in a file on the machine you are running on%')::text || ':' || ((public.skillhub_overview()->'read_this_first'->>2) like '%skillhub_load_text%')::text" "true:true:true"
# A document's TEXT in the store (2026-09-18): verbatim, with page markers, searchable by
# words with the matching passage as the excerpt, readable whole or by pages, indexed by
# meaning with the pages as chunk headings. Before this the catalogue knew a file's name and
# hash and nothing read inside it.
q "select public.skillhub_register_document('agent_01','QM-probe.pdf',12345,'application/pdf','0000probe','A probe manual written by the empty-database test','test', '0000probe/QM-probe.pdf')" >/dev/null
q "select public.document_set_content((select id from public.documents where sha256='0000probe'), E'QUALITY MANUAL\n\n4.1 Scope\nThis manual applies to every delivery.\n\n## Page 2\n7.3 Supplier surveillance\nEvery approved supplier is audited within twelve months of the last audit; the surveillance register holds the dates.\n\n## Page 3\n9.1 Records\nRecords are kept for ten years.', 3, 'agent_01')" >/dev/null
check "the text is stored with its page count" \
  "select pages::text || ':' || (content like '%## Page 3%')::text || ':' || (content_loaded_at is not null)::text from public.documents where sha256='0000probe'" "3:true:true"
check "the owner alone may load it" \
  "select coalesce((select 'set' from (select public.document_set_content((select id from public.documents where sha256='0000probe'), 'x', 1, 'agent_02')) z), '')" "ERROR:  Document $(q "select id from public.documents where sha256='0000probe'") belongs to agent_01. Only its owner or the caretaker may load its text."
check "a word inside the text is found, and the excerpt is the passage" \
  "select (count(*) = 1)::text || ':' || bool_and(excerpt like '%twelve months%')::text from platform.search('surveillance twelve months', 5) where source='document' and id=(select id::text from public.documents where sha256='0000probe')" "true:true"
check "read gives a page range, with the page headings kept" \
  "select (public.skillhub_read('document',(select id::text from public.documents where sha256='0000probe'),null,null,'2-3')->>'pages_returned') || ':' || ((public.skillhub_read('document',(select id::text from public.documents where sha256='0000probe'),null,null,'2')->>'content') like '## Page 2%Supplier surveillance%')::text || ':' || ((public.skillhub_read('document',(select id::text from public.documents where sha256='0000probe'),null,null,'2')->>'content') like '%9.1 Records%')::text" "2-3 of 3:true:false"
check "a page outside the document is refused, naming the range" \
  "select public.skillhub_read('document',(select id::text from public.documents where sha256='0000probe'),null,null,'9')->>'error'" "Pages are 1 to 3 for this document; \"9\" is outside that."
check "the catalogue view says it has text" \
  "select has_text::text || ':' || pages::text from platform.v_documents where filename='QM-probe.pdf'" "true:3"
check "and the indexer sees the text, cut with the pages as headings" \
  "select (count(*) >= 1)::text || ':' || bool_or(c->>'text' like '%twelve months%')::text from jsonb_array_elements(public.embed_candidates(1000, 300)) c where c->>'source'='document' and c->>'id'=(select id::text from public.documents where sha256='0000probe')" "true:true"
# Teams (2026-09-18): a third visibility between public and private. The word in
# public.agents.team is the whole mechanism -- same word, same team -- and every read path
# asks platform.may_read, so one probe per door: search, read, query, activity, and the
# indexer, which must NOT see it.
q "update public.agents set team = 'sales' where id in ('agent_01','agent_02')" >/dev/null
q "update public.agents set team = null where id = 'agent_03'" >/dev/null
check "existing tables accept team after the widening" \
  "select (count(*) = 0)::text from pg_constraint c join pg_namespace n on n.oid = c.connamespace where n.nspname = 'public' and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%visibility%' and pg_get_constraintdef(c.oid) not ilike '%''team''%'" "true"
q "select public.skillhub_write_note('agent_01','Sales team probe','The price list for the northern region is revised in March.', '{}', false, 'team')" >/dev/null
check "a team note is stored as one" \
  "select visibility || ':' || owner from public.notes where title='Sales team probe'" "team:agent_01"
check "a colleague in the team reads it, one outside does not, the caretaker does" \
  "select (public.skillhub_read('note',(select id::text from public.notes where title='Sales team probe'),'agent_02') ? 'content')::text || ':' || (public.skillhub_read('note',(select id::text from public.notes where title='Sales team probe'),'agent_03') ? 'content')::text || ':' || (public.skillhub_read('note',(select id::text from public.notes where title='Sales team probe'),'service_role') ? 'content')::text" "true:false:true"
check "search follows the same rule" \
  "select (select count(*) from platform.search('northern region price', 5, 'agent_02') where source='note')::text || ':' || (select count(*) from platform.search('northern region price', 5, 'agent_03') where source='note')::text || ':' || (select count(*) from platform.search('northern region price', 5, null) where source='note')::text" "1:0:0"
check "and the query tool" \
  "select (public.skillhub_query('agent_02','notes',array['count(*)'],'[[\"title\",\"=\",\"Sales team probe\"]]')->'rows'->0->>'count') || ':' || (public.skillhub_query('agent_03','notes',array['count(*)'],'[[\"title\",\"=\",\"Sales team probe\"]]')->'rows'->0->>'count')" "1:0"
check "the activity log shows the title to the team and hides it outside" \
  "select (public.skillhub_activity(50,'agent_02')::text like '%Sales team probe%')::text || ':' || (public.skillhub_activity(50,'agent_03')::text like '%Sales team probe%')::text || ':' || (public.skillhub_activity(50)::text like '%Sales team probe%')::text" "true:false:false"
check "the indexer never sees it" \
  "select (count(*) = 0)::text from jsonb_array_elements(public.embed_candidates(1000, 2000)) c where c->>'source'='note' and c->>'id'=(select id::text from public.notes where title='Sales team probe')" "true"
check "an agent with no team cannot write a team row" \
  "select coalesce((select 'wrote' from (select public.skillhub_write_note('agent_03','No team probe','x', '{}', false, 'team')) z), '')" "ERROR:  You (agent_03) are in no team, so there is nobody a team row would be shared with. Write it public or private, or ask the caretaker to set your team in the agents table."
check "the caretaker's standard says how to put an agent in a team" \
  "select version || ':' || (skill_md like '%5. Put an agent in a team%')::text || ':' || (skill_md like '%skillhub_record_sync%')::text from platform.v_current_skills where slug='caretaker-operations'" "1.4.0:true:true"
check "a public note by an agent with a team says so, in case the team was meant" \
  "select ((public.skillhub_write_note('agent_01','Public by a teamed agent','x')->>'note') like 'Public: every agent reads this. You are in team sales%')::text" "true"
q "delete from public.notes where title='Public by a teamed agent'" >/dev/null
# Feeds (2026-09-19): a table loaded once is a FILE and must never be reported as an overdue
# feed -- that is how an operating surface becomes noise. Three deliveries make a rhythm.
q "insert into platform.deliveries (source_system, target_table, agent, at, row_count) values ('Probe once','notes','service_role', now() - interval '40 days', 5)" >/dev/null
check "a table loaded once has no rhythm and is never quiet" \
  "select deliveries::text || ':' || coalesce(typical_gap::text,'-') || ':' || quiet::text from platform.v_sources where source_system='Probe once'" "1:-:false"
check "and health says nothing about it" \
  "select coalesce((select 'reported' from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='feeds'), 'silent')" "silent"
q "insert into platform.deliveries (source_system, target_table, agent, at, row_count) values ('Probe erp','notes','service_role', now() - interval '72 hours', 5),('Probe erp','notes','service_role', now() - interval '48 hours', 5),('Probe erp','notes','service_role', now() - interval '24 hours', 5)" >/dev/null
check "three loads give a rhythm, and on time is ok" \
  "select deliveries::text || ':' || typical_gap::text || ':' || quiet::text from platform.v_sources where source_system='Probe erp'" "3:24:00:00:false"
check "health counts the feed and says nothing is overdue" \
  "select (c->>'state') || ':' || ((c->>'detail') like '1 feed(s) deliver on a rhythm and none is overdue%')::text from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='feeds'" "ok:true"
q "update platform.deliveries set at = now() - interval '60 hours' where source_system='Probe erp' and at > now() - interval '30 hours'" >/dev/null
check "past twice its gap the feed is quiet, and health names it" \
  "select quiet::text from platform.v_sources where source_system='Probe erp'" "true"
check "and that is attention, never broken -- a quiet feed must not fail a cron" \
  "select (c->>'state') || ':' || ((c->>'detail') like '%notes from Probe erp, last%')::text from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='feeds'" "attention:true"
check "two systems into one table are two feeds, not one" \
  "select count(*)::text from platform.v_sources where table_name='notes'" "2"
q "delete from platform.deliveries where source_system like 'Probe %'" >/dev/null
# A run journal has a home (2026-09-20). Before this a delivery was file-shaped, so an agent
# mirroring an API had nowhere to record what a run did and wrote six notes instead -- and its
# twelve tables were invisible to the freshness view because nothing was registered.
q "select public.skillhub_record_sync('agent_01','Odoo','notes','crm.lead',39,2,1,36,0,'2026-09-19 23:28:29+00','run-a','first pass')" >/dev/null
check "a sync records itself as a delivery, not a note" \
  "select source_model||':'||rows_read::text||':'||skipped::text||':'||coalesce(watermark,'-')||':'||coalesce(run_id,'-') from platform.deliveries where source_system='Odoo'" "crm.lead:39:36:2026-09-19 23:28:29+00:run-a"
check "and that makes it a feed the freshness view can see" \
  "select source_system||':'||deliveries::text from platform.v_sources where source_system='Odoo'" "Odoo:1"
check "an unmoved watermark is named as an idle sync, not a broken one" \
  "select (public.skillhub_record_sync('agent_01','Odoo','notes','crm.lead',39,0,0,39,0,'2026-09-19 23:28:29+00','run-b')->>'recorded') like '%the watermark has not moved from 2026-09-19 23:28:29+00: the source had nothing newer%'" "t"
check "a sync against a table that does not exist says what that means" \
  "select coalesce((select 'recorded' from (select public.skillhub_record_sync('agent_01','Odoo','no_such_table','crm.lead')) z), '')" "ERROR:  No table \"no_such_table\" in public. Record a sync against the table it wrote to; if there is none yet, the rows had nowhere to go and that is the thing to report."
# The caller that matters for a mirror IS the caretaker, and an earlier draft refused it by
# re-checking the identity against public.agents -- a row that exists for a different reason.
check "the caretaker can record its own run" \
  "select (public.skillhub_record_sync('service_role','Odoo','notes','res.partner',36,36,0,0,0,'2026-09-20','run-c') ? 'recorded')::text" "true"
check "the run journal tells the agent what a note is for instead" \
  "select ((public.skillhub_record_sync('agent_01','Odoo','notes','crm.tag',8,0,0,8,0,null,'run-b')->>'next') like '%not in a note%')::text" "true"
q "delete from platform.deliveries where source_system='Odoo'" >/dev/null
# The caretaker's own queue is counted apart: nineteen requests filed to itself read as
# nineteen blocked colleagues until 2026-09-20.
q "insert into platform.structure_requests (requested_by, purpose, fields, status) values ('service_role','My own queue, filed while mirroring a CRM','[\"a\",\"b\"]'::jsonb,'open')" >/dev/null
check "the caretaker's own request is not reported as somebody waiting" \
  "select (c->>'state')||':'||((c->>'detail') like '%All 1 are your own queue%')::text from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='requests waiting on you'" "ok:true"
q "insert into platform.structure_requests (requested_by, purpose, fields, status) values ('agent_02','A colleague who is actually blocked','[\"a\"]'::jsonb,'open')" >/dev/null
check "and a real one is told apart from it" \
  "select ((c->>'detail') like '%1 from agents, who are blocked%1 are your own queue%')::text from jsonb_array_elements(platform.health()->'checks') c where c->>'check'='requests waiting on you'" "true"
q "delete from platform.structure_requests where purpose like '%own queue%' or purpose like '%actually blocked%'" >/dev/null
check "the mirror standard is published and says where a run journal goes" \
  "select version||':'||(skill_md like '%Do not write the run journal as a note%')::text||':'||(skill_md like '%rows read - inserted - updated = skipped%')::text from platform.v_current_skills where slug='mirror-a-live-system'" "1.0.0:true:true"
check "and the conventions skill lists it among the house standards" \
  "select (skill_md like '%mirror-a-live-system%')::text from platform.v_current_skills where slug='store-conventions'" "true"
check "whoami says which team" \
  "select (public.skillhub_whoami('agent_01')->>'team') || ':' || coalesce(public.skillhub_whoami('agent_03')->>'team','none')" "sales:none"
# Loaded rows were public whatever the loader asked for until 2026-09-19: a department's own
# feed had nowhere to land. The caretaker is refused with a different sentence, because a
# team row it OWNED would be readable by nobody at all.
q "select public.create_shared_table('probe_feed','Probe table for the loaded-rows visibility check')" >/dev/null
q "alter table public.probe_feed add column order_no text, add column amount text" >/dev/null
q "select public.skillhub_load_rows('agent_01','probe_feed','order_no','[{\"order_no\":\"A-1\",\"amount\":\"10\"}]'::jsonb,null,null,'Probe ERP',false,'team')" >/dev/null
check "loaded rows take the visibility the loader asked for" \
  "select visibility || ':' || owner from public.probe_feed where order_no='A-1'" "team:agent_01"
check "and the caretaker is told why a team row of its own would reach nobody" \
  "select coalesce((select 'loaded' from (select public.skillhub_load_rows('service_role','probe_feed','order_no','[{\"order_no\":\"A-2\"}]'::jsonb,null,null,'Probe ERP',false,'team')) z), '')" "ERROR:  A team row belongs to a team through its OWNER, and you have none -- rows you own with visibility = team would be readable by you alone. Have the department's own agent write or load them, or set the team on the rows afterwards together with an owner that is in it."
check "an outsider counts none of them, the team-mate counts one" \
  "select (public.skillhub_query('agent_02','probe_feed',array['count(*)'])->'rows'->0->>'count') || ':' || (public.skillhub_query('agent_03','probe_feed',array['count(*)'])->'rows'->0->>'count')" "1:0"
q "drop table public.probe_feed" >/dev/null
q "delete from public.notes where title='Sales team probe'" >/dev/null
q "update public.agents set team = null" >/dev/null
check "retiring the note works too" \
  "select (public.skillhub_retire('agent_01','note',(select id::text from public.notes where title='Seed test'),'seed test cleanup') ? 'retired_by')::text" "true"

echo
if [ "$fail" = "0" ]; then echo "PASS -- an empty database and this repo give a working data store."
else echo "FAIL -- see above."; fi
exit "$fail"
