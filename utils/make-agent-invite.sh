#!/bin/sh
# Fill the invite template for one agent.
#
#   sh utils/make-agent-invite.sh <agent-id> <public-url> [env-file] [output-file]
#   e.g. sh utils/make-agent-invite.sh agent_04 https://data.example.com
#
# The key -> agent binding is made in volumes/api/kong.yml ($MCP_KEY_NN -> username
# agent_NN), so nothing about it belongs in this script or in the database. Who is BEHIND
# agent_NN is a separate, optional label an admin writes in public.agents -- see the comment
# on that table, including why every agent can read it.
#
# Reads MCP_KEY_NN for that agent from the deployed .env (default: the Easypanel
# path) and writes a ready-to-paste invite to $HOME/.skillhub-invites/.
#
# The output is a SECRET. It holds a live key next to the public address, and that
# pair is usable by whoever finds it without any further guesswork -- a scanner
# caught exactly that combination in this repository once already. So the script
# refuses to write anywhere git can see, checked before the key is ever read.
set -eu

U="usage: make-agent-invite.sh <agent-id> <public-url> [env-file] [output-file]"
AGENT="${1:?$U}"
PUBLIC_URL="${2:?$U}"
ENVFILE="${3:-/etc/easypanel/projects/data/supabase/code/.env}"
OUT="${4:-$HOME/.skillhub-invites/invite-$AGENT-$(date +%Y%m%d-%H%M%S).md}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "$AGENT" in
  agent_0[1-9]|agent_10) ;;
  *) echo "Agent id must be agent_01 .. agent_10, got '$AGENT'."; exit 1 ;;
esac

# Walk up for .git rather than asking git: as root on a checkout owned by another
# user, `git rev-parse` exits non-zero with "dubious ownership", and a guard that
# reads that as "not a repository" writes the secret straight into the repository.
OUTDIR="$(dirname "$OUT")"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
d="$OUTDIR"
while [ "$d" != "/" ]; do
  if [ -e "$d/.git" ]; then
    echo "Refusing to write an invite into a git working tree: $d"
    echo "Give a path outside any repository, or omit it to use \$HOME/.skillhub-invites/."
    exit 1
  fi
  d="$(dirname "$d")"
done
[ -e "$OUT" ] && { echo "$OUT already exists; move it away first."; exit 1; }

SLOT="${AGENT#agent_}"
[ -r "$ENVFILE" ] || { echo "Cannot read $ENVFILE. Pass the env file as the third argument."; exit 1; }
KEY="$(grep "^MCP_KEY_${SLOT}=" "$ENVFILE" | cut -d= -f2-)"
[ -n "$KEY" ] || { echo "MCP_KEY_${SLOT} is empty in $ENVFILE. Fill that slot and redeploy Kong first:"; \
  echo "  docker compose -p data_supabase --env-file .env -f docker-compose.yml -f docker-compose.override.yml up -d --no-deps --force-recreate kong"; exit 1; }

chmod 700 "$OUTDIR" 2>/dev/null || true
umask 077
sed -e "s|<agent_NN>|$AGENT|g" \
    -e "s|<KEY>|$KEY|g" \
    -e "s|<STORE URL>|$PUBLIC_URL|g" \
    "$REPO/utils/agent-invite.md" > "$OUT"
chmod 600 "$OUT"

echo "Wrote $OUT"
echo
echo "Paste everything BELOW the '---' line into a fresh Hermes chat on that device."
echo "Then: shred -u '$OUT' -- the Environment panel is the system of record, not this file."
echo
echo "Verify afterwards: the agent should report skillhub_whoami = $AGENT."
echo "If it reports a different agent, the wrong key reached that machine."
echo
echo "Optional: if this person's name or role should be visible to the other agents,"
echo "an admin sets it on the $AGENT row in public.agents -- in Studio or in SQL."
echo "It is a label, not a control: the key already decides which agent_NN you are."
