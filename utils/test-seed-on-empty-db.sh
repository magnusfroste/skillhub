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
n=0; until docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 || [ $n -ge 90 ]; do sleep 2; n=$((n+1)); done
[ $n -lt 90 ] || { echo "   database never became ready"; exit 1; }
echo "   ready"

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

echo
if [ "$fail" = "0" ]; then echo "PASS -- an empty database and this repo give a working data store."
else echo "FAIL -- see above."; fi
exit "$fail"
