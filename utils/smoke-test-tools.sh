#!/bin/sh
# Call every house tool once through the gateway and report which ones error.
#
#   sh utils/smoke-test-tools.sh <store-url> <agent-key>
#
# Why this exists. Four tools shipped broken and stayed broken unnoticed:
# skillhub_publish_skill, skillhub_retire, skillhub_register_document and
# skillhub_request_structure each failed on EVERY call they ever received, because a parameter
# shared a name with a column and Postgres refuses an unqualified reference with "column
# reference is ambiguous". Two of them had been in the repo for days. publish_skill -- the tool
# at the centre of "agents publish so colleagues reuse" -- had never once succeeded.
#
# None of it was visible from the outside: agents did the job with raw SQL instead, so nothing
# looked wrong. A broken door goes unnoticed for as long as the door is optional, and once it is
# not optional, a broken tool is an outage.
#
# These are the parameters that collide with a column name somewhere in public, i.e. where the
# next one will come from:
#   add_rows           visibility
#   publish_skill      slug, name, content, description, tags, version
#   read               id
#   register_document  filename, bytes, mime_type, sha256, description, source
#   retire             id, superseded_by
#   write_note         title, content, tags
# Qualify every reference to those with the function name and this test stays green.
#
# It writes: a note, a skill, a document record, a structure request and one row in a table you
# name. Run it against a store you do not mind leaving five test rows in, and clean up after.
set -eu

URL="${1:?usage: smoke-test-tools.sh <store-url> <agent-key> [table-for-add-rows]}"
KEY="${2:?usage: smoke-test-tools.sh <store-url> <agent-key> [table-for-add-rows]}"
ROWTABLE="${3:-}"

# The last raw response, so a later step can read what a tool returned. The retire step
# used to search for the note it had just written and parse the pretty-printed hit with
# sed; that broke silently when the result envelope changed, and the test then reported
# "skip" for retire on every run while leaving a note, a skill and a document behind in
# every store it was pointed at. write_note, publish_skill and register_document all
# RETURN the identifier of what they wrote. Use that.
LAST=""
call() {
  name="$1"; args="$2"
  body=$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$name" "$args")
  out=$(curl -s -X POST "$URL/skillhub" \
        -H "apikey: $KEY" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' -d "$body" 2>/dev/null || true)
  LAST="$out"
  if printf '%s' "$out" | grep -q '"isError":true'; then
    printf '  FAIL  %-28s %s\n' "$name" "$(printf '%s' "$out" | sed -n 's/.*"text":"\(.\{0,100\}\).*/\1/p')"
    FAILED=$((FAILED+1))
  elif printf '%s' "$out" | grep -q '"result"'; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %-28s no result: %s\n' "$name" "$(printf '%s' "$out" | head -c 100)"
    FAILED=$((FAILED+1))
  fi
}

FAILED=0
LONG=$(awk 'BEGIN{for(i=0;i<4;i++)printf "A documented procedure long enough to clear the two hundred character floor. "}')

echo "Reading:"
call skillhub_overview '{}'
call skillhub_rules '{}'
call skillhub_search '{"query":"convention"}'
call skillhub_read '{"kind":"table","id":"notes"}'
call skillhub_similar '{"query":"how should this data be read"}'
call skillhub_activity '{"max_rows":5}'
call skillhub_query '{"table_name":"notes","columns":["count(*)"]}'
call skillhub_whoami '{}'
call skillhub_report '{"days":1}'

# Key out of the tool's JSON text (result.content[0].text is itself JSON). python3 where
# it exists -- it is on every host this runs from -- with a sed fallback for a flat key.
field() {
  key="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$LAST" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); t=json.loads(d["result"]["content"][0]["text"]); v=t.get(sys.argv[1]); print(v if v is not None else "")
except Exception: print("")' "$key" 2>/dev/null
  else
    printf '%s' "$LAST" | sed -n "s/.*\\\"$key\\\": *\\\"\([^\\]*\)\\\".*/\1/p" | head -1
  fi
}

echo "Writing:"
call skillhub_write_note "$(printf '{"title":"smoke test %s","content":"Written by utils/smoke-test-tools.sh"}' "$(date -u +%Y%m%d%H%M%S)")"
NOTEID=$(field id)
# A slug unique to this run. The gate refuses publishing over an existing version -- correctly
# -- so a fixed slug made the second run on any store fail on publish_skill. The retired
# rows from earlier runs stay, as retired rows do; the change log says which run wrote them.
RUN=$(date -u +%Y%m%d%H%M%S)
call skillhub_publish_skill "$(printf '{"slug":"smoke-test-%s","name":"Smoke test %s","content":"%s"}' "$RUN" "$RUN" "$LONG")"
SKILLSLUG=$(field slug)
call skillhub_register_document '{"filename":"smoke-test.pdf","description":"Written by the smoke test","sha256":"0000smoke"}'
DOCID=$(field id)
call skillhub_request_structure '{"purpose":"Smoke test of the structure request channel","fields":["a","b"]}'
REQID=$(field id)
[ -n "$ROWTABLE" ] && call skillhub_add_rows "$(printf '{"table_name":"%s","rows":[{}]}' "$ROWTABLE")" || \
  echo "  skip  skillhub_add_rows (pass a table name as the third argument)"
echo "Cleaning up: retiring what this run wrote (this is the retire test)"
n=0
for spec in "note:$NOTEID" "skill:$SKILLSLUG" "document:$DOCID"; do
  kind=${spec%%:*}; id=${spec#*:}
  if [ -n "$id" ]; then
    call skillhub_retire "$(printf '{"kind":"%s","id":"%s","reason":"smoke test cleanup"}' "$kind" "$id")"
    n=$((n+1))
  else
    printf '  FAIL  skillhub_retire (%s) -- the write returned no identifier to retire\n' "$kind"
    FAILED=$((FAILED+1))
  fi
done
if [ -n "$REQID" ]; then
  echo "  note  one structure request is left OPEN ($REQID): agents cannot close requests, the"
  echo "        caretaker does -- select platform.resolve_structure_request('$REQID', ...). That is the design, not litter."
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All tools answered."
else
  echo "$FAILED tool(s) failed. If the message says \"column reference ... is ambiguous\", a"
  echo "parameter shares a name with a column: qualify it with the function name."
  exit 1
fi
