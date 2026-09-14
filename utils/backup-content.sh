#!/bin/sh
# Dump what only the running instance holds: the content and the change log.
#
#   sh utils/backup-content.sh [output-dir]
#
# The repo reproduces the HOUSE -- conventions, change log, placement rule, the fifteen
# tools -- and utils/test-seed-on-empty-db.sh proves it against an empty database. What the
# repo cannot reproduce is what agents and people put there: the loaded exports, the notes,
# the published skills, and the history of who did what. Some of it has no source left. On
# 2026-09-14 the export behind 5,812 quality rows was no longer anywhere on disk.
#
# Two dumps, because they answer different questions:
#   full.dump      everything, custom format -- restore the instance as it was
#   content.sql    data only, plain SQL -- pour the content into a freshly seeded store
#
# Written outside any git working tree, checked before anything is read: a dump holds the
# organisation's data, and the same guard is on prepare-easypanel-env.sh for the same reason.
set -eu

OUT="${1:-$HOME/.skillhub-backups/$(date +%Y%m%d-%H%M%S)}"
CONTAINER="${DB_CONTAINER:-supabase-db}"
USER_="${DB_USER:-postgres}"
DB="${DB_NAME:-postgres}"

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
d="$OUT"
while [ "$d" != "/" ]; do
  if [ -e "$d/.git" ]; then
    echo "Refusing to write a dump into a git working tree: $d"; exit 1
  fi
  d="$(dirname "$d")"
done
chmod 700 "$OUT" 2>/dev/null || true
umask 077

echo "Backing up from container $CONTAINER"
docker exec "$CONTAINER" pg_dump -U "$USER_" -d "$DB" -Fc \
  --schema=public --schema=platform > "$OUT/full.dump"
docker exec "$CONTAINER" pg_dump -U "$USER_" -d "$DB" --data-only \
  --schema=public --schema=platform > "$OUT/content.sql"

docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -At -F' ' -c "
select relname, n_live_tup from pg_stat_user_tables
 where schemaname in ('public','platform') and n_live_tup > 0 order by 2 desc;" > "$OUT/inventory.txt"

chmod 600 "$OUT"/* 2>/dev/null || true
echo "Wrote:"
ls -lh "$OUT" | awk 'NR>1{print "  "$9"  "$5}'
echo
echo "To restore onto a FRESHLY SEEDED store (the house already in place):"
echo "  docker exec -i $CONTAINER psql -U $USER_ -d $DB < $OUT/content.sql"
echo "To restore the instance as it was:"
echo "  docker exec -i $CONTAINER pg_restore -U $USER_ -d $DB --clean --if-exists < $OUT/full.dump"
