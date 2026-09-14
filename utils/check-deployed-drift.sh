#!/bin/sh
# What is actually running, compared with what git says is running.
#
#   sh utils/check-deployed-drift.sh [deployed-checkout]
#
# There are TWO clones of this repo on an Easypanel host. This one, where you edit, and
# the one Easypanel pulls into /etc/easypanel/projects/<project>/<service>/code/, which is
# the one the containers mount. Editing here changes nothing until you commit, push and
# deploy -- and editing THERE changes everything immediately while git knows nothing.
#
# Written 2026-09-14 after finding the deployed checkout 28 commits behind AND dirty: three
# files had been edited in place, among them volumes/api/kong.yml carrying the rule that
# closed the raw SQL door to agent keys. That rule existed only as an uncommitted edit on a
# server. A deploy would have replaced it with the committed version and reopened the door,
# silently, and the next person to look would have found agents able to write rows under a
# colleague's name again. Nothing was lost, but only because the contents happened to match.
#
# Run this before and after every deploy.
set -eu

DEPLOYED="${1:-/etc/easypanel/projects/data/supabase/code}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

[ -d "$DEPLOYED" ] || { echo "No deployed checkout at $DEPLOYED. Pass the path as an argument."; exit 1; }

echo "working copy : $REPO"
echo "deployed     : $DEPLOYED"
echo

echo "--- commits"
printf "  working copy : %s\n" "$(git -C "$REPO" -c safe.directory="$REPO" log --oneline -1 2>/dev/null || echo '?')"
printf "  deployed     : %s\n" "$(git -C "$DEPLOYED" -c safe.directory="$DEPLOYED" log --oneline -1 2>/dev/null || echo '?')"
BEHIND="$(git -C "$REPO" -c safe.directory="$REPO" rev-list --count \
          "$(git -C "$DEPLOYED" -c safe.directory="$DEPLOYED" rev-parse HEAD 2>/dev/null)"..HEAD 2>/dev/null || echo '?')"
echo "  deployed is $BEHIND commit(s) behind the working copy"
echo

echo "--- uncommitted edits on the DEPLOYED side (invisible to git, lost on the next deploy)"
DIRTY="$(git -C "$DEPLOYED" -c safe.directory="$DEPLOYED" status --porcelain 2>/dev/null || true)"
if [ -z "$DIRTY" ]; then
  echo "  none"
else
  echo "$DIRTY" | sed 's/^/  /'
  echo
  echo "  Each of these is running right now and exists in no commit. Copy them into the"
  echo "  working copy, commit, push and deploy -- or they go away the next time anyone"
  echo "  presses Deploy, without a warning and without a diff."
fi
echo

echo "--- files the CONTAINERS read: do they match what you would deploy?"
for f in volumes/api/kong.yml volumes/functions/skillhub/index.ts volumes/functions/embed/index.ts docker-compose.yml; do
  if [ ! -f "$DEPLOYED/$f" ]; then printf "  %-40s MISSING on the deployed side\n" "$f"
  elif cmp -s "$REPO/$f" "$DEPLOYED/$f"; then printf "  %-40s same\n" "$f"
  else printf "  %-40s DIFFERS\n" "$f"
  fi
done
echo

cat <<'NOTE'
--- how each layer picks up a change
  volumes/api/kong.yml      read at CONTAINER CREATION. A restart keeps the old routes,
                            consumers and ACL in memory. Recreate:
                              docker compose -p data_supabase --env-file .env \
                                -f docker-compose.yml -f docker-compose.override.yml \
                                up -d --no-deps --force-recreate kong
  volumes/functions/*       read at container start. Restart supabase-edge-functions.
  demo/*.sql                these are FUNCTIONS IN POSTGRES. Applying them with psql takes
                            effect on the next call -- no deploy, and no commit either, so
                            the database can run SQL that exists in no file. Re-apply from
                            the repo after editing, and keep the two in step.
NOTE
