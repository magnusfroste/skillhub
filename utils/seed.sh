#!/bin/sh
# Apply the shared data store to a database. Idempotent: safe to run on every boot.
#
#   sh utils/seed.sh                      # against the running supabase-db container
#   sh utils/seed.sh "postgresql://..."   # against any reachable database
#
# WHY THIS RUNS EVERY TIME, not only on first init.
#
# The SQL in demo/ IS the data store: the conventions, the change log, the placement rule,
# the fifteen tools, every refusal message an agent ever reads. Until 2026-09-14 none of it
# was applied by anything -- it was run by hand with psql. That leaves the same gap we found
# in the file layer that day, where volumes/api/kong.yml had been edited on the server and
# the rule closing the raw SQL door existed in no commit. A database can drift from the repo
# exactly the same way, and nothing would show it.
#
# Applying on every boot closes it: what runs IS what is committed, checked each time the
# stack comes up. Every statement is create-or-replace or if-not-exists, so re-applying is a
# no-op on an up-to-date database -- verified against an empty one by
# utils/test-seed-on-empty-db.sh, which is the receipt that a fresh deploy gives a working
# store rather than fifteen tools that answer with errors.
#
# ORDER IS DATA, NOT ALPHABET. It was found by running against an empty database until it
# went through, not by reading the files. Do not sort this list.
set -eu

# Resolve to a clean absolute path. Mounted at /seed.sh inside the seed container, dirname
# is "/" and "/.." is "/", and the naive form printed "///demo" in every deploy log.
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
REPO="${REPO%/}"   # "" when mounted at the root, so "${REPO}/demo" is "/demo", not "//demo"
DSN="${1:-}"

FILES="skill_library.sql conventions.sql platform.sql platform_lifecycle.sql platform_loading.sql platform_entry.sql platform_vector.sql platform_embed.sql platform_ops.sql platform_tools.sql"

run() {
  if [ -n "$DSN" ]; then
    psql "$DSN" -v ON_ERROR_STOP=1 -q -f "$1"
  else
    docker exec -i "${DB_CONTAINER:-supabase-db}" psql -U "${DB_USER:-supabase_admin}" \
      -d "${DB_NAME:-postgres}" -v ON_ERROR_STOP=1 -q < "$1"
  fi
}

# Record the run in the store itself. A failed seed was visible only in docker logs, which
# nobody reads: on 2026-09-16 platform.sql failed on an instance at 4,096 dimensions and
# every file after it was skipped. platform.health() reads this and says broken. It is also
# how health dates the last boot -- honestly, now that boots no longer write to the change log.
record() {
  printf "create schema if not exists platform;
create table if not exists platform.seed_runs (at timestamptz not null default now(), ok int, failed_file text, error text);
insert into platform.seed_runs (ok, failed_file, error) values (%s, %s, %s);
delete from platform.seed_runs where at < now() - interval '30 days';\n" \
    "$1" "$2" "$3" > "$REPO/.seed-note.sql"
  run "$REPO/.seed-note.sql" >/dev/null 2>&1 || true
  rm -f "$REPO/.seed-note.sql"
}
sqlq() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }

echo "Seeding the shared data store from ${REPO}/demo"
N=0
for f in $FILES; do
  [ -f "$REPO/demo/$f" ] || { echo "  MISSING $f -- the store would be incomplete, stopping."; exit 1; }
  printf '  %-26s ' "$f"
  if run "$REPO/demo/$f" >/dev/null 2>"$REPO/.seed-err"; then
    echo ok; N=$((N+1))
  else
    echo FAILED
    sed 's/^/    /' "$REPO/.seed-err" | head -20
    record "$N" "$(sqlq "$f")" "$(sqlq "$(grep -m1 ERROR "$REPO/.seed-err" || head -c 300 "$REPO/.seed-err")")"
    rm -f "$REPO/.seed-err"
    exit 1
  fi
done
rm -f "$REPO/.seed-err"
record "$N" null null
echo "Done. Re-running this changes nothing on an up-to-date database."
