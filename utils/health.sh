#!/bin/sh
# Is the store healthy? One call, for a person or a monitor.
#
#   sh utils/health.sh https://<store> <SERVICE_ROLE_KEY>
#   sh utils/health.sh https://<store> "$SERVICE_ROLE_KEY" --quiet    # cron: silent unless broken
#
# Exit code 0 when nothing is wrong, 1 when something is BROKEN -- and only then, or a
# monitor stops being read. Things merely waiting (an unanswered request, no backup for a
# week, meaning search switched off on purpose) print but do not fail: they are work, not
# incidents.
#
# Every fault this repository found in its first fortnight was found because somebody
# happened to look: a house standard that had gone stale, a cron that swallowed its own
# failures, a skill that grew four sections a boot for two weeks, vectors that outlived the
# objects they pointed at. The store could answer all of it. Nothing asked.
set -eu

URL="${1:?Give the store's URL, e.g. https://store.example.com}"
KEY="${2:?Give SERVICE_ROLE_KEY -- this is the caretaker's view, not an agent's}"
QUIET=""
[ "${3:-}" = "--quiet" ] && QUIET=1

URL="${URL%/}"
body="$(curl -s -m 60 -A skillhub-health -X POST "$URL/rest/v1/rpc/skillhub_health" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H 'content-type: application/json' -d '{}' || true)"

printf %s "$body" | HEALTH_QUIET="$QUIET" python3 -c '
import sys, json, os
quiet = bool(os.environ.get("HEALTH_QUIET"))
raw = sys.stdin.read()
try:
    h = json.loads(raw)
except Exception:
    print("The store did not answer with health. It said:"); print("  " + raw[:400]); sys.exit(1)
if not isinstance(h, dict) or "verdict" not in h:
    print("The store answered, but not with health. It said:"); print("  " + raw[:400])
    print()
    print("A 404 here means the SQL is older than this script: re-run the seed.")
    print("A 401 means the key is not the service key.")
    sys.exit(1)

v = h["verdict"]
if quiet and v != "broken":
    sys.exit(0)

mark = {"ok": "  ", "attention": "~ ", "broken": "! "}
print("%s  --  %s" % (v.upper(), h.get("meaning", "")))
print("%s" % h.get("at", ""))
print()
for c in h.get("checks") or []:
    print("%s%-24s %s" % (mark.get(c.get("state"), "  "), c.get("check", ""), c.get("detail", "")))
    if c.get("run") and c.get("state") != "ok":
        print("%*s%s" % (28, "", c["run"]))
        if c.get("changes"):
            print("%*schanges: %s" % (28, "", c["changes"]))
print()
look = h.get("look") or []
dec = h.get("decide") or []
if look:
    print("Safe to run now, all of it:")
    for l in look: print("  " + l)
if dec:
    print()
    print("Decisions, not steps -- say what you found and let a person answer:")
    for d in dec: print("  %s: %s" % (d.get("about"), d.get("call")))
sys.exit(1 if v == "broken" else 0)
' 2>&1
