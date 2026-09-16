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

echo "Seeding the shared data store from ${REPO}/demo"
for f in $FILES; do
  [ -f "$REPO/demo/$f" ] || { echo "  MISSING $f -- the store would be incomplete, stopping."; exit 1; }
  printf '  %-26s ' "$f"
  if run "$REPO/demo/$f" >/dev/null 2>"$REPO/.seed-err"; then
    echo ok
  else
    echo FAILED
    sed 's/^/    /' "$REPO/.seed-err" | head -20
    rm -f "$REPO/.seed-err"
    exit 1
  fi
done
rm -f "$REPO/.seed-err"
echo "Done. Re-running this changes nothing on an up-to-date database."
