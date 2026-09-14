#!/bin/sh
# Produce a ready-to-paste Environment for an Easypanel Compose service.
#
#   sh utils/prepare-easypanel-env.sh <public-url> <dashboard-username> [mcp-key-slots] [output-file]
#   e.g. sh utils/prepare-easypanel-env.sh https://data.example.com admin 2
#
# Writes example.env plus fresh secrets, the three public URLs, DASHBOARD_USERNAME and N
# random MCP_KEY_xx values. Paste the contents into the service's Environment panel BEFORE
# the first deploy; Postgres role passwords are burned in at first init (see README).
#
# The output NEVER goes into this checkout. An earlier version wrote ./.env.compact here;
# a .gitignore covering only the exact name ".env" let it through and `git add -A` pushed
# every secret in it to a public repository — together with the public URL, which is what
# makes a leaked key usable without any guesswork. A scanner caught it, not us.
# So the default target is outside any repository, and the script refuses to write into a
# git working tree at all, checked before a single secret is generated.
set -eu

PUBLIC_URL="${1:?usage: prepare-easypanel-env.sh <public-url> <dashboard-username> [mcp-key-slots] [output-file]}"
DASH_USER="${2:?usage: prepare-easypanel-env.sh <public-url> <dashboard-username> [mcp-key-slots] [output-file]}"
SLOTS="${3:-0}"
OUT="${4:-$HOME/.supabase-secrets/supabase-$(date +%Y%m%d-%H%M%S).env}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
command -v openssl >/dev/null || { echo "openssl is required"; exit 1; }

# Refuse to write anywhere git can see. Checked first, so a refusal leaves nothing behind.
#
# Walk up looking for .git rather than asking git: as root on a checkout owned by another
# user, `git rev-parse` exits non-zero with "dubious ownership", and a guard that reads that
# as "not a repository" writes the secrets straight into the repository. That is exactly how
# this went wrong the first time, in a different disguise. The filesystem cannot lie here.
OUTDIR="$(dirname "$OUT")"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
d="$OUTDIR"
while [ "$d" != "/" ]; do
  if [ -e "$d/.git" ]; then
    echo "Refusing to write secrets into a git working tree: $d"
    echo "Give an output path outside any repository, or omit it to use \$HOME/.supabase-secrets/."
    exit 1
  fi
  d="$(dirname "$d")"
done
[ -e "$OUT" ] && { echo "$OUT already exists; move it away first."; exit 1; }

chmod 700 "$OUTDIR" 2>/dev/null || true
umask 077
cp "$REPO/example.env" "$OUT"

# generate-keys.sh --update-env rewrites ./.env relative to the current directory, so run
# it in a scratch directory and take the result from there. Nothing is left in the repo.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
cp "$OUT" "$TMP/.env"
( cd "$TMP" && sh "$REPO/utils/generate-keys.sh" --update-env >/dev/null )
cp "$TMP/.env" "$OUT"

sed -i \
  -e "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=${PUBLIC_URL}|" \
  -e "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=${PUBLIC_URL}/auth/v1|" \
  -e "s|^SITE_URL=.*|SITE_URL=${PUBLIC_URL}|" \
  -e "s|^DASHBOARD_USERNAME=.*|DASHBOARD_USERNAME=${DASH_USER}|" \
  "$OUT"

i=1
while [ "$i" -le "$SLOTS" ] && [ "$i" -le 10 ]; do
  slot=$(printf '%02d' "$i")
  sed -i "s|^MCP_KEY_${slot}=.*|MCP_KEY_${slot}=$(openssl rand -hex 32)|" "$OUT"
  i=$((i+1))
done

chmod 600 "$OUT"
echo "Wrote $OUT"
echo "Filled: JWT_SECRET ANON_KEY SERVICE_ROLE_KEY POSTGRES_PASSWORD DASHBOARD_PASSWORD SECRET_KEY_BASE"
echo "        VAULT_ENC_KEY PG_META_CRYPTO_KEY REALTIME_DB_ENC_KEY LOGFLARE_* S3_PROTOCOL_* MINIO_ROOT_PASSWORD"
echo "        SUPABASE_PUBLIC_URL API_EXTERNAL_URL SITE_URL DASHBOARD_USERNAME MCP_KEY_01..$(printf '%02d' "$SLOTS")"
echo
echo "Next:  cat '$OUT'   ->  paste into the Easypanel Environment panel  ->  Deploy"
echo "Then:  shred -u '$OUT'   — the panel is the system of record, not this file."
echo
echo "The file holds every secret AND the public URL. Keep that pair out of repositories,"
echo "chats and tickets: together they are immediately usable by whoever finds them."
