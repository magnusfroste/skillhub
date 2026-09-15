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

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
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

q() { docker exec "$NAME" psql -U postgres -At -c "$1"; }

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
check "the fifteen tools exist" \
  "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'skillhub_%'" "15"
check "rules are readable" \
  "select (public.skillhub_rules() ? 'placement_rule')::text" "true"
check "overview answers" \
  "select (public.skillhub_overview() is not null)::text" "true"
check "the conventions skill is there, once" \
  "select count(*) from public.skill_library where slug='store-conventions'" "1"
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
check "retiring the note works too" \
  "select (public.skillhub_retire('agent_01','note',(select id::text from public.notes where title='Seed test'),'seed test cleanup') ? 'retired_by')::text" "true"

echo
if [ "$fail" = "0" ]; then echo "PASS -- an empty database and this repo give a working data store."
else echo "FAIL -- see above."; fi
exit "$fail"
