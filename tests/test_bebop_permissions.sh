#!/usr/bin/env bash
# Regression guard for Claude Code auto-mode denials under CLAUDE_CONFIG_DIR fences.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEBOP="$REPO/bebop.sh"

count=$(grep -Ec 'claude --permission-mode acceptEdits' "$BEBOP")
[[ $count == 8 ]] || { echo "FAIL: expected 8 writable launch surfaces, found $count" >&2; exit 1; }
! grep -Eq 'claude --permission-mode auto([[:space:]]|$)' "$BEBOP" || {
  echo "FAIL: writable launch explicitly selects auto mode" >&2; exit 1;
}
grep -q 'claude -p "\$question" --model "\$model" --permission-mode plan' "$BEBOP" || {
  echo "FAIL: read-only ask entrypoint lost plan mode" >&2; exit 1;
}
wiggum_body=$(awk '
  /^bebop_wiggum_proposer\(\) \{/ { inside=1 }
  inside && /^bebop_ask\(\) \{/ { exit }
  inside { print }
' "$BEBOP")
! grep -q -- '--permission-mode' <<<"$wiggum_body" || {
  echo "FAIL: Wiggum proposer must retain its caller-owned bypass policy" >&2; exit 1;
}

# Exercise every primary single-model backend and aliases without a model call.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@"
FAKE
chmod +x "$tmp/claude"
export PATH="$tmp:$PATH"
hash -r
# shellcheck source=/dev/null
set +e
. "$BEBOP"
set -e
for variant in compass qwen qwen3.8 q5 muse qwen-big qwen35 nemotron nemo auto gpt gpt-5.5 sol gpt-5.6-sol; do
  output=$(bebop "$variant" -p harmless 2>/dev/null)
  grep -qx -- '--permission-mode' <<<"$output"
  grep -qx 'acceptEdits' <<<"$output"
done

echo "PASS: writable Bebop variants avoid auto mode; read-only/autonomous policies preserved"
