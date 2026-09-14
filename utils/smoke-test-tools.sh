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

call() {
  name="$1"; args="$2"
  body=$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$name" "$args")
  out=$(curl -s -X POST "$URL/skillhub" \
        -H "apikey: $KEY" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' -d "$body" 2>/dev/null || true)
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

echo "Writing:"
call skillhub_write_note '{"title":"smoke test","content":"Written by utils/smoke-test-tools.sh"}'
call skillhub_publish_skill "$(printf '{"slug":"smoke-test-skill","name":"Smoke test","content":"%s"}' "$LONG")"
call skillhub_register_document '{"filename":"smoke-test.pdf","description":"Written by the smoke test","sha256":"0000smoke"}'
call skillhub_request_structure '{"purpose":"Smoke test of the structure request channel","fields":["a","b"]}'
[ -n "$ROWTABLE" ] && call skillhub_add_rows "$(printf '{"table_name":"%s","rows":[{}]}' "$ROWTABLE")" || \
  echo "  skip  skillhub_add_rows (pass a table name as the third argument)"
echo "  note  skillhub_retire is exercised by retiring the note this run created:"
NOTEID=$(curl -s -X POST "$URL/skillhub" -H "apikey: $KEY" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skillhub_search","arguments":{"query":"smoke test"}}}' 2>/dev/null \
  | sed -n 's/.*"kind": "note",\\n *"id": "\([^"]*\)".*/\1/p' | head -1)
if [ -n "$NOTEID" ]; then
  call skillhub_retire "$(printf '{"kind":"note","id":"%s","reason":"smoke test cleanup"}' "$NOTEID")"
else
  echo "  skip  skillhub_retire (could not find the note just written)"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All tools answered."
else
  echo "$FAILED tool(s) failed. If the message says \"column reference ... is ambiguous\", a"
  echo "parameter shares a name with a column: qualify it with the function name."
  exit 1
fi
