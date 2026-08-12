#!/usr/bin/env bash
# Binding & reference coverage for the gpu_rtx_3090 rename.
#
# Proves that after renaming /root/gpu_rtx_9030 -> /root/gpu_rtx_3090 nothing that
# depends on the old path is left dangling. Read-only: it asserts, it never mutates
# live state. Safe to run repeatedly and in CI (GPU-absent aware).
#
#   bash tests/test_bindings.sh
#
# Exit 0 = all assertions green. Exit 1 = at least one failure.
set -u

NEW=/root/gpu_rtx_3090
OLD=gpu_rtx_9030
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0 fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
# assert_eq <label> <expected> <actual>
assert_eq() { [ "$2" = "$3" ] && ok "$1" || no "$1 (expected '$2', got '$3')"; }
# assert <label> ; runs remaining args as a command, pass if exit 0
assert() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else no "$l"; fi; }

echo "== Binding integrity (B1-B5) =="

# 1. systemd ExecStop points at the new path
execstop=$(systemctl cat gpu-safe-shutdown.service 2>/dev/null | sed -n 's/^ExecStop=//p' | awk '{print $1}')
case "$execstop" in
  "$NEW"/*) ok "1. systemd ExecStop under $NEW ($execstop)";;
  *)        no "1. systemd ExecStop not under $NEW (got '$execstop')";;
esac

# 2. ExecStop target is an executable file
assert "2. ExecStop target is executable" test -x "$execstop"

# 3. unit still enabled + active after daemon-reload
assert_eq "3a. unit enabled" "enabled" "$(systemctl is-enabled gpu-safe-shutdown.service 2>/dev/null)"
assert_eq "3b. unit active"  "active"  "$(systemctl is-active  gpu-safe-shutdown.service 2>/dev/null)"

# 4. gpu-ops skill symlink resolves under the new path (no dangling link)
link=$(readlink -e /root/.claude/skills/gpu-ops 2>/dev/null)
case "$link" in
  "$NEW"/*) ok "4. gpu-ops symlink resolves under $NEW ($link)";;
  *)        no "4. gpu-ops symlink dangling or wrong (got '$link')";;
esac

# 5. settings.local.json valid JSON, 7 new-path entries, 0 old
SETTINGS=/root/.claude/settings.local.json
assert "5a. settings.local.json parses as JSON" python3 -c "import json,sys; json.load(open('$SETTINGS'))"
# 5b. The rename left >= 7 new-path entries; the allowlist legitimately grows as new
#     gpu_rtx_3090 commands are approved, so assert the floor, not a frozen snapshot count.
new_entries=$(grep -c "$NEW" "$SETTINGS")
if [ "$new_entries" -ge 7 ]; then ok "5b. new-path entries >= 7 (have $new_entries)"; else no "5b. new-path entries < 7 (have $new_entries)"; fi
assert_eq "5c. old-path entries == 0" "0" "$(grep -c "$OLD" "$SETTINGS")"

# 6. repo-copy unit ExecStop path is the new path
repo_execstop=$(sed -n 's/^ExecStop=//p' "$REPO/gpu-safe-shutdown.service" | awk '{print $1}')
case "$repo_execstop" in
  "$NEW"/*) ok "6. repo unit ExecStop under $NEW";;
  *)        no "6. repo unit ExecStop wrong (got '$repo_execstop')";;
esac

# 7. git remote origin points at the renamed repo
remote=$(git -C "$REPO" remote get-url origin 2>/dev/null)
case "$remote" in
  *gpu_rtx_3090.git) ok "7. git remote -> $remote";;
  *)                 no "7. git remote not gpu_rtx_3090.git (got '$remote')";;
esac

echo "== Script self-binding (internal refs survived the move) =="

for s in gpu-status.sh gpu-safe-shutdown.sh gpu-power-up.sh; do
  # 8. syntax
  assert "8. bash -n $s" bash -n "$REPO/$s"
  # 9. its sourced lib.sh sits beside it
  if grep -q 'source "\$DIR/lib.sh"' "$REPO/$s"; then
    assert "9. $s -> lib.sh resolvable" test -f "$REPO/lib.sh"
  fi
done
# lib.sh itself
assert "8. bash -n lib.sh" bash -n "$REPO/lib.sh"

# 10. shellcheck (optional — only if installed)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "$REPO"/*.sh >/dev/null 2>&1; then
    ok "10. shellcheck (severity=error) clean"
  else
    no "10. shellcheck reported errors"
  fi
else
  ok "10. shellcheck not installed — skipped"
fi

echo "== bebop Muse routing invariants =="
BEBOP="$REPO/bebop.sh"
assert "Muse canonical route -> muse-glimmer-30b" grep -Eq '^    \[muse\]=muse-glimmer-30b([[:space:]]|$)' "$BEBOP"
assert "deprecated qwen-big alias -> Muse" grep -Eq '^    \[qwen-big\]=muse-glimmer-30b([[:space:]]|$)' "$BEBOP"
assert "deprecated qwen35 alias -> Muse" grep -Eq '^    \[qwen35\]=muse-glimmer-30b([[:space:]]|$)' "$BEBOP"
assert "Muse context is 131072" grep -Eq '^    \[muse\]=131072([[:space:]]|$)' "$BEBOP"
assert "agent-pack default is Muse" grep -q 'AGENTPACK_LOCAL_MODEL="${AGENTPACK_LOCAL_MODEL:-muse-glimmer-30b}"' "$BEBOP"
assert "team-local default is Muse" grep -q 'AGENTPACK_LOCAL_MODEL:-muse-glimmer-30b' "$BEBOP"
assert "Muse thinking route is rejected" grep -q '\[ "$model" = muse-glimmer-30b \]' "$BEBOP"
assert_eq "Muse think is not advertised" "0" "$(grep -Eci 'bebop (muse|qwen-big|qwen35)-think' "$BEBOP")"
assert "true Qwen 27B route unchanged" grep -Eq '^    \[qwen\]=qwen3\.6-27b([[:space:]]|$)' "$BEBOP"
assert "true Qwen coder route unchanged" grep -Eq '^    \[coder\]=qwen3-coder-30b-a3b([[:space:]]|$)' "$BEBOP"
assert_eq "retired 35B backend has no live mapping" "0" "$(grep -Ec '^    \[[^]]+\]=qwen3\.6-35b-a3b([[:space:]]|$)' "$BEBOP")"

# 11. gpu-status.sh runs at the new path without a path/source error.
#     GPU may be absent in CI, so we only fail on 'No such file' / source failures,
#     not on a graceful GPU-missing exit.
out=$(bash "$REPO/gpu-status.sh" 2>&1); rc=$?
if echo "$out" | grep -qiE 'No such file or directory|cannot open|lib\.sh'; then
  no "11. gpu-status.sh path/source error (rc=$rc)"
else
  ok "11. gpu-status.sh executes at new path (rc=$rc, no path/source error)"
fi

echo "== Reference hygiene (B6 + global sweep) =="

# 12. Global sweep excluding historical caches and the rename guard files
#     themselves (this harness + the CI workflow legitimately name the old path
#     in order to detect it). `.wiggum/` is the spec-driven loop's bookkeeping
#     (proof captures, verdicts, run logs) — it quotes this harness's own output
#     verbatim, including the "no live <OLD>" PASS line, so it is a cache, not a
#     live reference; excluded like tasks/ and .claude/projects/.
sweep=$(grep -rn "$OLD" /root \
          --exclude-dir=.git --exclude-dir=file-history --exclude-dir=.vscode-server \
          --exclude-dir=tasks --exclude-dir=.wiggum \
          2>/dev/null \
        | grep -v '/.claude/history.jsonl' \
        | grep -v '/.bash_history' \
        | grep -v '/.claude/plans/' \
        | grep -v '/.claude/projects/-root' \
        | grep -v "$REPO/tests/test_bindings.sh" \
        | grep -v "$REPO/.github/workflows/bindings.yml")
if [ -z "$sweep" ]; then
  ok "12. global sweep clean (no live $OLD references)"
else
  no "12. global sweep found live $OLD references:"; echo "$sweep" | sed 's/^/       /'
fi

# 13. in-repo sweep (exclude the guard files that must name the old path to detect it)
repo_hits=$(grep -rln "$OLD" "$REPO" 2>/dev/null \
             | grep -v "$REPO/tests/test_bindings.sh" \
             | grep -v "$REPO/.github/workflows/bindings.yml" \
             | grep -v "$REPO/.git/")
assert_eq "13. in-repo sweep clean" "" "$repo_hits"

# 14. each cross-repo / external file clean
for f in \
  /root/mairp.github.io/index.html \
  /root/mairp-digital-twin/src/knowledge-base.js \
  /root/proxmox-ops/skills/fleet-control/SKILL.md \
  /root/llama-swap/README.md \
  /root/roadmap/eGPU-3090-phase2-roadmap.md \
  /root/.openclaw/workspace-netops/skills/fleet-control/SKILL.md \
  /root/openclaw-dr/captured/workspace-netops/skills/fleet-control/SKILL.md ; do
  [ -f "$f" ] || { ok "14. (absent, skipped) $f"; continue; }
  assert_eq "14. clean: $f" "0" "$(grep -c "$OLD" "$f")"
done

# 15. portal href uses the new repo URL
assert "15. mairp.github.io href -> gpu_rtx_3090" \
  grep -q 'github.com/mairp/gpu_rtx_3090' /root/mairp.github.io/index.html

echo "== Remote / GitHub (B4) =="
# 16 + 17. Only if gh is available and authenticated.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  assert_eq "16. gh repo name" "gpu_rtx_3090" \
    "$(gh repo view mairp/gpu_rtx_3090 --json name -q .name 2>/dev/null)"
  assert_eq "17. old URL redirects" "gpu_rtx_3090" \
    "$(gh repo view mairp/gpu_rtx_9030 --json name -q .name 2>/dev/null)"
else
  ok "16. gh unavailable/unauth — remote checks skipped"
  ok "17. gh unavailable/unauth — redirect check skipped"
fi

echo "== agent-pack fences (roadmap 14.1, Phase 9) =="
# 18. The agent pack's own invariant guard (session/role/permission fences). Its script
#     lives beside the pack; run it if present and fold its exit into one assertion here so
#     a broken fence (bad skill name, Skill leaking past `spec`, a dangling profile link,
#     gridctl resurrected, an unfenced entrypoint) fails this binding suite too.
AGENTPACK_TESTS="${AGENTPACK_TESTS:-/root/agent-pack/tests/test_agentpack.sh}"
if [ -f "$AGENTPACK_TESTS" ]; then
  if bash "$AGENTPACK_TESTS" >/tmp/agentpack-fences.$$.log 2>&1; then
    ok "18. agent-pack fences green ($(grep -oE 'PASS: [0-9]+' /tmp/agentpack-fences.$$.log | tail -1))"
  else
    no "18. agent-pack fences FAILED — see below"
    sed 's/^/       /' /tmp/agentpack-fences.$$.log
  fi
  rm -f /tmp/agentpack-fences.$$.log
else
  ok "18. agent-pack tests absent ($AGENTPACK_TESTS) — skipped"
fi

echo "== governed-fleet invariants (roadmap 15.1, Phase 12) =="
# 19. The 15.1 governed-fleet invariant guard (compose reuses live organs / port band /
#     append-only audit / forbidden-key filter / recall provenance / card≠approval / config
#     drift / Wiggum unmodified). Its script lives in the WFO repo; run it if present and fold
#     its exit into one assertion so a broken governed invariant fails this binding suite too.
GOVERNED_FLEET_TESTS="${GOVERNED_FLEET_TESTS:-/root/workflow_orchestration/tests/test_governed_fleet.sh}"
if [ -f "$GOVERNED_FLEET_TESTS" ]; then
  if bash "$GOVERNED_FLEET_TESTS" >/tmp/governed-fleet.$$.log 2>&1; then
    ok "19. governed-fleet invariants green ($(grep -oE 'PASS: [0-9]+' /tmp/governed-fleet.$$.log | tail -1))"
  else
    no "19. governed-fleet invariants FAILED — see below"
    sed 's/^/       /' /tmp/governed-fleet.$$.log
  fi
  rm -f /tmp/governed-fleet.$$.log
else
  ok "19. governed-fleet tests absent ($GOVERNED_FLEET_TESTS) — skipped"
fi

echo
echo "======================================"
echo "  PASS: $pass    FAIL: $fail"
echo "======================================"
[ "$fail" -eq 0 ]
