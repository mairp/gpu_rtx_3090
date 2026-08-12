#!/usr/bin/env bash
# antares-scan: point the local antares-1b (Granite-4.0) model at a folder and have
# it flag likely security issues, ONE FILE AT A TIME (the model's -c 8192 context and
# text-only, no-tools nature means it cannot crawl a tree itself — this wrapper feeds
# it each file). A 1B is a cheap FIRST-PASS smell test only: it misses a lot. For real
# review use `bebop muse` / gpt-5 / a proper SAST tool. See antares() in bebop.sh.
#
# Usage:
#   antares-scan.sh <folder> [--ext "py,js,ts,go,sh"] [--max-bytes 12000]
#
# Notes:
# - Only text source files are scanned; large files are truncated to --max-bytes
#   (~ what fits in the 8k context) and the truncation is flagged in the output.
# - Findings print per file; a "no obvious issues" line means the model saw nothing,
#   NOT that the file is safe.
set -u

FOLDER=""
EXTS="py,js,ts,jsx,tsx,go,rb,php,java,sh,bash,c,cpp,cc,h,rs,yaml,yml,json,env,tf,sql"
MAX_BYTES=12000
LITELLM_URL="http://127.0.0.1:4000/v1/chat/completions"

while [ $# -gt 0 ]; do
  case "$1" in
    --ext)       EXTS="$2"; shift 2 ;;
    --max-bytes) MAX_BYTES="$2"; shift 2 ;;
    -h|--help)   grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           FOLDER="$1"; shift ;;
  esac
done

if [ -z "$FOLDER" ] || [ ! -d "$FOLDER" ]; then
  echo "usage: antares-scan.sh <folder> [--ext \"py,js,...\"] [--max-bytes N]" >&2
  exit 2
fi

KEY=$(grep -m1 '^LITELLM_MASTER_KEY=' /root/litellm/.env | cut -d= -f2)
if [ -z "$KEY" ]; then
  echo "antares-scan: could not read LITELLM_MASTER_KEY from /root/litellm/.env" >&2
  exit 1
fi

# Build a find expression from the extension list.
find_args=()
IFS=',' read -ra EXT_ARR <<< "$EXTS"
for e in "${EXT_ARR[@]}"; do
  e="${e// /}"
  [ -z "$e" ] && continue
  find_args+=(-iname "*.${e}" -o)
done
unset 'find_args[${#find_args[@]}-1]'   # drop trailing -o

# The instruction goes in the USER turn, NOT a system role: this 1B ignores a
# system-role reviewer persona but follows an inline instruction (measured). An
# explicit checklist beats an open "find vulns" ask, and we deliberately DO NOT
# offer a "reply NO ISSUES" escape hatch — it made the model lazily bail.
REVIEW_INSTR="Review this code for security vulnerabilities. Check specifically for: SQL injection, command injection, template/code injection, hardcoded secrets or credentials, unsafe deserialization, path traversal, weak crypto, missing authentication/authorization, SSRF, and unsafe eval/exec. For EACH issue you find state: the type, the exact line or snippet, and the fix. Be concise."

count=0
mapfile -d '' files < <(find "$FOLDER" -type f \( "${find_args[@]}" \) -not -path '*/.git/*' -print0 2>/dev/null)

echo "== antares-scan: ${#files[@]} file(s) under $FOLDER =="
echo "== (1B first-pass smell test — misses issues; not a substitute for real review) =="
echo

for f in "${files[@]}"; do
  count=$((count+1))
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  note=""
  if [ "$sz" -gt "$MAX_BYTES" ]; then
    note=" [TRUNCATED to ${MAX_BYTES}B of ${sz}B — rerun on this file alone for full coverage]"
  fi
  content=$(head -c "$MAX_BYTES" "$f")

  body=$(jq -n --arg instr "$REVIEW_INSTR" \
              --arg p "File: $f${note}"$'\n\n''```'$'\n'"$content"$'\n''```' '{
    model: "antares",
    messages: [ {role:"user", content: ($instr + "\n\n" + $p)} ],
    max_tokens: 1024,
    temperature: 0
  }')

  resp=$(curl -s -m 120 "$LITELLM_URL" \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$body")
  out=$(echo "$resp" | jq -e -r '.choices[0].message.content' 2>/dev/null)

  echo "### [$count/${#files[@]}] $f${note}"
  if [ -n "$out" ]; then
    echo "$out"
  else
    echo "  (request error: $(echo "$resp" | jq -r '.error.message // .message // .' 2>/dev/null | head -c 200))"
  fi
  echo
done
