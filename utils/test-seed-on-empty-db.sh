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
check "the seventeen skillhub_ functions exist" \
  "select count(distinct proname) from pg_proc where proname like 'skillhub\\_%'" "17"
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
q "select public.index_run_save(jsonb_build_object('model','probe','dimension',1536,'objects',3,'embedded',3,'chunks',4,'truncated',0,'failed',0,'requests',1,'pruned',0,'seconds',0.4))" >/dev/null
check "a run is remembered, so flapping is answerable" \
  "select count(*)::text || ':' || (platform.health()->'checks' @> '[{\"check\":\"indexing, last 24h\"}]')::text from platform.index_runs" "1:true"
q "select public.backup_record('content','/root/.skillhub-backups/probe',1024,'written by the empty-database test')" >/dev/null
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
check "retiring the note works too" \
  "select (public.skillhub_retire('agent_01','note',(select id::text from public.notes where title='Seed test'),'seed test cleanup') ? 'retired_by')::text" "true"

echo
if [ "$fail" = "0" ]; then echo "PASS -- an empty database and this repo give a working data store."
else echo "FAIL -- see above."; fi
exit "$fail"
