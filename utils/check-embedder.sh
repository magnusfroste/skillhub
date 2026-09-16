#!/bin/sh
# Will this embedding endpoint work as this store's indexer?
#
#   sh utils/check-embedder.sh <EMBEDDING_URL> [EMBEDDING_MODEL] [EMBEDDING_KEY]
#   sh utils/check-embedder.sh http://10.0.0.5:8008/v1/embeddings embed
#
# Run it from the machine that will host the store -- not from a laptop. Half of what can
# go wrong is that the endpoint is reachable from where you are testing and not from where
# the container runs, and nothing downstream says so in those words: the store reports
# "the endpoint answered 404" or nothing at all, five minutes later, in a cron.
#
# It asks the endpoint exactly what volumes/functions/embed asks it, in the same order,
# and prints what the store would write into platform.embedder. Nothing is changed
# anywhere; this touches no database.
set -eu

URL="${1:?Give the endpoint, e.g. http://host:8008/v1/embeddings (a bare host or a /v1 base is completed for you)}"
MODEL="${2:-embed}"
KEY="${3:-}"

# Same completion the indexer does, so what you test is what it will call.
case "$URL" in
  */embeddings) ;;
  */v1|*/v1/)   URL="${URL%/}/embeddings" ;;
  *)            case "$(printf %s "$URL" | sed 's|^[a-z]*://[^/]*||')" in
                  ""|"/") URL="${URL%/}/v1/embeddings" ;;
                esac ;;
esac
BASE="$(printf %s "$URL" | sed 's|\(^[a-z]*://[^/]*\).*|\1|')"
auth_curl() { if [ -n "$KEY" ]; then curl -s -m 60 -A skillhub-preflight -H "Authorization: Bearer $KEY" "$@";
              else curl -s -m 60 -A skillhub-preflight "$@"; fi; }

echo "Endpoint: $URL"
echo "Model:    $MODEL"
echo "Key:      $([ -n "$KEY" ] && echo "set" || echo "none")"
echo

fail=0
say() { printf '  %-44s %s\n' "$1" "$2"; }

# 1. Is it there at all, and does it embed?
probe="$(auth_curl -X POST "$URL" -H 'content-type: application/json' \
          -d "{\"model\":\"$MODEL\",\"input\":[\"probe\"]}" || true)"
DIM="$(printf %s "$probe" | python3 -c '
import sys,json
try: print(len(json.load(sys.stdin)["data"][0]["embedding"]))
except Exception: print(0)' 2>/dev/null || echo 0)"
if [ "$DIM" -eq 0 ]; then
  say "the endpoint embeds" "NO"
  echo
  echo "  It answered: $(printf %s "$probe" | head -c 300)"
  echo
  echo "  Check the URL and the model name. From inside a container the host is not"
  echo "  localhost -- use the machine's address on the network the stack is joined to."
  exit 1
fi
say "the endpoint embeds" "yes"
say "dimension the model returns" "$DIM"

# 2. What the store will do with that dimension.
if [ "$DIM" -le 2000 ]; then IDX="an HNSW index";
elif [ "$DIM" -le 4000 ]; then IDX="a half-precision HNSW index";
else IDX="NO index -- exact scans, which is fine below tens of thousands of objects"; fi
say "the vector store will be built with" "$IDX"

# 3. How much text one input may carry, asked the way the indexer asks.
TOK=0; FROM=""
info="$(auth_curl "$BASE/info" || true)"
TOK="$(printf %s "$info" | python3 -c '
import sys,json
try: print(int(json.load(sys.stdin).get("max_input_length") or 0))
except Exception: print(0)' 2>/dev/null || echo 0)"
[ "$TOK" -gt 0 ] && FROM="tei /info"
if [ "$TOK" -eq 0 ]; then
  models="$(auth_curl "$BASE/v1/models" || true)"
  TOK="$(printf %s "$models" | MODEL="$MODEL" python3 -c '
import sys,json,os
try:
  d=json.load(sys.stdin); want=os.environ["MODEL"]
  m=next((x for x in d.get("data",[]) if x.get("id")==want), None) or (d.get("data") or [None])[0]
  print(int((m or {}).get("max_model_len") or 0))
except Exception: print(0)' 2>/dev/null || echo 0)"
  [ "$TOK" -gt 0 ] && FROM="vllm /v1/models"
fi
if [ "$TOK" -gt 0 ]; then say "input limit it reports" "$TOK tokens ($FROM)"
else say "input limit it reports" "none -- sizes will be tried instead"; fi

# 4. Characters per token on this store's kind of text, from the endpoint's own usage.
SAMPLE="$(python3 -c '
s=("Avvikelsen registrerades i kvalitetsregistret med leverantorens artikelnummer och en kort beskrivning av felet. "
   "The supplier surveillance rule says every approved supplier is audited within twelve months of the last audit. "
   "Kolumnen hours_spent innehaller vardet 999 for arenden dar tiden inte registrerats; exkludera dem ur summor. "
   "Register the document, keep its own clause numbering, and never present condensed text inside quotation marks. ")*3
print(s[:1000])')"
usage="$(auth_curl -X POST "$URL" -H 'content-type: application/json' \
          -d "$(python3 -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"input":[sys.argv[2]]}))' "$MODEL" "$SAMPLE")" || true)"
PT="$(printf %s "$usage" | python3 -c '
import sys,json
try: print(int(json.load(sys.stdin).get("usage",{}).get("prompt_tokens") or 0))
except Exception: print(0)' 2>/dev/null || echo 0)"
if [ "$PT" -gt 0 ]; then
  RATIO="$(python3 -c "print(round(1000/$PT,2))")"
  say "characters per token, measured" "$RATIO"
  if [ "$TOK" -gt 0 ]; then
    CHARS="$(python3 -c "print(int($TOK*1000/$PT*0.85))")"
    say "chunk size the store will choose" "$CHARS characters"
  fi
else
  say "characters per token" "not reported -- 3.0 assumed"
fi

# 5. A batch of eight, the default. A server that refuses this refuses every run.
batch="$(auth_curl -X POST "$URL" -H 'content-type: application/json' \
          -d "$(python3 -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"input":[sys.argv[2]]*8}))' "$MODEL" "$SAMPLE")" || true)"
N="$(printf %s "$batch" | python3 -c '
import sys,json
try: print(len(json.load(sys.stdin)["data"]))
except Exception: print(0)' 2>/dev/null || echo 0)"
if [ "$N" -eq 8 ]; then say "eight inputs in one request" "yes"
else say "eight inputs in one request" "NO -- set EMBEDDING_MAX_INPUTS lower"; fail=1; fi

# 6. What happens to an input over the limit: refused, or cut?
if [ "$TOK" -gt 0 ]; then
  BIG="$(python3 -c "print('lorem ipsum dolor sit amet '*$((TOK*2)))")"
  over="$(auth_curl -o /dev/null -w '%{http_code}' -X POST "$URL" -H 'content-type: application/json' \
           -d "$(python3 -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"input":[sys.argv[2]]}))' "$MODEL" "$BIG")" || true)"
  if [ "$over" = "200" ]; then say "an input over the limit" "accepted (it truncates by itself)"
  else
    trunc="$(auth_curl -o /dev/null -w '%{http_code}' -X POST "$URL" -H 'content-type: application/json' \
             -d "$(python3 -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"input":[sys.argv[2]],"truncate_prompt_tokens":int(sys.argv[3])}))' "$MODEL" "$BIG" "$TOK")" || true)"
    if [ "$trunc" = "200" ]; then say "an input over the limit" "refused ($over), truncate_prompt_tokens works"
    else say "an input over the limit" "refused ($over), and truncation too ($trunc)"; fail=1; fi
  fi
fi

echo
if [ "$fail" = "0" ]; then
  echo "PASS -- set these three and the indexer works out the rest:"
  echo
  echo "  EMBEDDING_URL=$URL"
  echo "  EMBEDDING_MODEL=$MODEL"
  # The key is not echoed: this output gets pasted into chats and tickets.
  echo "  EMBEDDING_KEY=$([ -n "$KEY" ] && echo "<the key you passed>" || echo "")"
  echo
  echo "After the first deploy, ask any agent for skillhub_overview and read \"index\":"
  echo "meaning_search on, the dimension above, waiting 0, last_error null."
else
  echo "FAIL -- see the lines above. The store would still install and keyword search would"
  echo "work; search by meaning is what is at stake."
  exit 1
fi
