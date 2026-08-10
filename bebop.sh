# shellcheck shell=bash
# This file is SOURCED by ~/.bashrc (not executed), so it has no shebang; the
# directive above tells shellcheck the target shell (fixes SC2148 in CI).
#
# bebop: Claude Code via cc-compass-shim (127.0.0.1:8088). First arg picks a backend;
# everything after passes through to `claude`, e.g.  bebop qwen -p "hi".
#
#   bebop            -> Compass (STAGE), default model claude-opus-4.8   (no arg = compass)
#   bebop compass    -> same, explicit
# Local models on the RTX 3090 (fully local via llama-swap; one loads at a time):
#   bebop qwen       -> Qwen3.6-27B   (dense Q4_K_M, fast, no thinking)
#   bebop qwen-big   -> Qwen3.6-35B-A3B  (MoE, larger)          alias: qwen35
#   bebop coder      -> Qwen3-Coder-30B-A3B-Instruct  (coding specialist, -c 65536)
#   bebop auto       -> qwen-auto (LiteLLM picks: reasoning->gpt-5, coding->coder, big->35B, else sticky local)
# Cloud models on Compass STAGE (NOT llama-swap — via the shim's OPENAI_MODELS path):
#   bebop gpt        -> Compass gpt-5.5      (cloud reasoning model; alias: gpt-5.5)
#   bebop sol        -> Compass gpt-5.6-sol  (cloud reasoning model; alias: gpt-5.6-sol)
#   bebop qwen-fp4   -> Qwen3.6-27B NVFP4  (only after Step 6 promotion; else falls back to 27B)
#   add "-think" for the reasoning variant, e.g.  bebop qwen-think / bebop qwen-big-think
#
# bebop v3 — the frontier-fading agent TREE (roadmap 12.1; opus plans, qwen executes):
#   bebop team [args...]        -> orchestrator (opus-4.8) + agent pack loaded; plan-first
#   bebop team-local [args...]  -> same tree, orchestrator = qwen35 (the destination config)
#   bebop ask <role> "q"        -> headless READ-ONLY leaf, no orchestrator hop (S1b)
#                                  roles: investigator (fleet/AIOps), librarian (recall/docs)
#   bebop ai-ops [args...]      -> the DIRECTOR entrypoint (Phase 4): main-thread ai-ops role,
#                                  ops affinity model, fenced to the ai-ops profile (7 skills)
#   Agent pack lives in $AGENTPACK_HOME (default /root/agent-pack); models resolve per
#   LOCAL/DEGRADED mode at launch. See gpu_rtx_3090/README.md for the full surface.
#
# To add/repoint a local model: edit the `models` table below (alias -> llama-swap name).
# The shim injects the real backend keys, so ANTHROPIC_AUTH_TOKEN is a placeholder.
#
# Version-controlled in github.com/mairp/gpu_rtx_3090 (bebop.sh); ~/.bashrc sources this
# file, so edit HERE and commit — not in .bashrc.
unalias bebop 2>/dev/null   # drop any stale alias so the function below always parses on re-source
bebop() {
  # alias -> backend model name. Add a line here to expose a new model.
  # Local models resolve to llama-swap names (one loads at a time). NVFP4 stays commented
  # until the benchmark promotes it (see llama-swap/config.yaml + shim QWEN_MODELS).
  # `gpt*` are CLOUD models served through the shim's OPENAI_MODELS path (Compass STAGE via
  # LiteLLM), not llama-swap — the "one model at a time / swap-thrash" rationale below does
  # NOT apply to them; they're just routed through the shim's Anthropic<->OpenAI translator.
  local -A models=(
    [qwen]=qwen3.6-27b
    [qwen-big]=qwen3.6-35b-a3b
    [qwen35]=qwen3.6-35b-a3b
    [coder]=qwen3-coder-30b-a3b  # coding-specialist MoE (roadmap 11.1); served -c 65536
    [auto]=qwen-auto           # LiteLLM auto-router: reasoning->gpt-5, coding->coder, big->35b, else sticky
    [gpt]=gpt-5.5              # cloud: Compass STAGE gpt-5.5 via shim OPENAI_MODELS (NOT llama-swap)
    [gpt-5.5]=gpt-5.5         # explicit-name alias for the same
    [sol]=gpt-5.6-sol         # cloud: Compass STAGE gpt-5.6-sol via shim OPENAI_MODELS (NOT llama-swap)
    [gpt-5.6-sol]=gpt-5.6-sol # explicit-name alias for the same
    # [qwen-fp4]=qwen3.6-27b-nvfp4
  )
  # Real served context per backend (llama-swap `-c`, raised 2026-07-12). Claude Code
  # honors CLAUDE_CODE_MAX_CONTEXT_TOKENS for non-claude-* models: telling it the true
  # window makes it AUTO-COMPACT before the shim's overflow 400 — frontier behavior
  # instead of "prompt exceeds context, start a new session". auto uses the 35B window
  # because the qwen-auto router sends every big job to the 35B.
  local -A ctxs=(
    [qwen]=98304
    [qwen-big]=131072
    [qwen35]=131072
    [coder]=65536              # matches llama-swap `-c 65536` for the coder (VRAM headroom)
    [auto]=131072
    [gpt]=200000              # gpt-5.5: shim QWEN_CTX_MAP entry gpt-5.5:200000 (spec 002 fix) -> match it
    [gpt-5.5]=200000         # so Claude Code auto-compacts at the true 200k, not an artificial 98304 floor
    [sol]=200000              # gpt-5.6-sol: shim QWEN_CTX_MAP entry gpt-5.6-sol:200000 (spec 002 fix) -> match it
    [gpt-5.6-sol]=200000     # so Claude Code auto-compacts at the true 200k, not an artificial 98304 floor
  )
  local sel=${1:-compass} think=
  # bebop v3 subcommands (Phase 2): the agent tree. Dispatch to their functions and
  # return — they own the whole arg tail. Single-model entrypoints below are unchanged.
  case "$sel" in
    team)       shift; bebop_team "$@"; return ;;
    team-local) shift; bebop_team_local "$@"; return ;;
    ask)        shift; bebop_ask "$@"; return ;;
    ai-ops)     shift; bebop_ai_ops "$@"; return ;;
    spec)       shift; bebop_spec "$@"; return ;;
    wiggum-proposer) shift; bebop_wiggum_proposer "$@"; return ;;
  esac
  case "$sel" in
    -*) sel=compass ;;                 # no backend given, just claude args -> compass
    *-think) sel=${sel%-think}; think=1; shift ;;
    *) shift ;;
  esac

  # Compass passthrough (default / explicit).
  if [ "$sel" = compass ]; then
    ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy claude "$@"
    return
  fi

  local model=${models[$sel]}
  if [ -z "$model" ]; then
    echo "bebop: unknown backend '$sel' (try: compass, ${!models[*]}, or append -think)" >&2
    return 2
  fi

  # ANTHROPIC_SMALL_FAST_MODEL is deliberately the SAME model as the main one:
  # llama-swap holds one model in 24 GB, so background subagent calls to any
  # OTHER local model would force a full disk reload each way (35B<->27B swap
  # thrash, minutes per switch). Same model = zero swaps; the "cost" of running
  # a title-gen on the big model is noise next to a single reload.
  # MAX_THINKING_TOKENS makes Claude Code request thinking; the shim auto-detects it
  # and streams qwen's reasoning back as Anthropic thinking blocks (context-hungry).
  local ctx=${ctxs[$sel]:-98304}
  if [ -n "$think" ]; then
    ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy \
    ANTHROPIC_MODEL=$model ANTHROPIC_SMALL_FAST_MODEL=$model \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=$ctx \
    MAX_THINKING_TOKENS=8000 CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000 \
    claude "$@"
  else
    ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy \
    ANTHROPIC_MODEL=$model ANTHROPIC_SMALL_FAST_MODEL=$model \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=$ctx \
    CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000 \
    claude "$@"
  fi
}

# ============================================================================
# bebop v3 — the frontier-fading agent tree (roadmap 12.1, Phase 2). ADDITIVE:
# the single-model entrypoints above are untouched. These three launch Claude
# Code on the shim with the agent-pack loaded (opus plans, qwen executes).
#
#   bebop team [claude args...]        interactive/headless orchestrator (opus-4.8)
#   bebop team-local [claude args...]  same tree, orchestrator = qwen35 (the goal config)
#   bebop ask <role> "question"        headless read-only leaf, no orchestrator hop (S1b)
#
# The agent pack (roles, contracts, escalation, config) lives in $AGENTPACK_HOME
# (default /root/agent-pack). Its `agentops` bootstrap resolves each role's model for
# the current LOCAL/DEGRADED mode and emits the whole pack as one `claude --agents`
# JSON object — so the tree is injected WITHOUT writing into the user's repo, and the
# role .md files stay the single source of truth. Config lives in agentpack.conf.
# ============================================================================
AGENTPACK_HOME="${AGENTPACK_HOME:-/root/agent-pack}"
_bebop_agentops() { "$AGENTPACK_HOME/bin/agentops" "$@"; }

# _bebop_profile_launch <profile> [claude args…] — the ONE session-fence launcher every
# new entrypoint (Phase 4 ai-ops, Phase 5 spec, Phase 6 wiggum-proposer) routes through.
# It re-homes the config layer to profiles/<profile>/ via CLAUDE_CONFIG_DIR (so only that
# profile's skills, its settings.json OTel+kanban hooks, and its scoped MCP are visible),
# forces --strict-mcp-config --mcp-config <profile>/mcp.json, and runs on the shim. The
# skill/MCP scoping is the fence; model routing is still the caller's job (export
# ANTHROPIC_MODEL/…/--model before calling). Returns non-zero with a message if the
# profile dir or the pack is missing.
_bebop_profile_launch() {
  local profile="${1:-}"; shift || true
  if [ -z "$profile" ]; then
    echo "bebop: _bebop_profile_launch needs a profile name" >&2; return 2
  fi
  if [ ! -x "$AGENTPACK_HOME/bin/agentops" ]; then
    echo "bebop: agent pack not found at $AGENTPACK_HOME (set AGENTPACK_HOME)" >&2; return 1
  fi
  local dir="${AGENTPACK_PROFILES_DIR:-$AGENTPACK_HOME/profiles}/$profile"
  if [ ! -d "$dir" ] || [ ! -f "$dir/mcp.json" ]; then
    echo "bebop: no such profile '$profile' (looked in $dir)" >&2; return 1
  fi
  # Shim env (frontier via 127.0.0.1:8088) unless the caller already pinned a base URL.
  export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:8088}"
  export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-dummy}"
  export AGENTPACK_HOME
  # CLAUDE_CONFIG_DIR displaces the whole /root/.claude user layer -> the profile's
  # settings.json re-provides the OTel env + kanban hooks; strict-MCP + mcp.json fence
  # the servers. Everything after is passed straight to claude.
  CLAUDE_CONFIG_DIR="$dir" \
    claude --strict-mcp-config --mcp-config "$dir/mcp.json" "$@"
}

# _bebop_profile_dir <profile> — echo the on-disk profile directory (holds skills/,
# settings.json, mcp.json). Falls back to a synthesized empty-profile dir under TMPDIR if
# the named profile is missing, so a launch never breaks (rule 1). This is the Phase 2
# default: every agent-pack entrypoint (team, team-local, ask) routes through a profile via
# CLAUDE_CONFIG_DIR=<dir> --strict-mcp-config --mcp-config <dir>/mcp.json, so the dead
# gridctl + qmd/pvectl schemas never load into an agent session.
_bebop_profile_dir() {
  local profile="${1:-team}"
  local dir="${AGENTPACK_PROFILES_DIR:-$AGENTPACK_HOME/profiles}/$profile"
  if [ -f "$dir/mcp.json" ]; then
    printf '%s' "$dir"
  else
    # No profile on disk: synthesize a minimal empty profile so strict-MCP still fences.
    local fb="${TMPDIR:-/tmp}/agentpack-empty-profile"
    mkdir -p "$fb"
    [ -f "$fb/mcp.json" ] || printf '{"mcpServers":{}}' > "$fb/mcp.json"
    printf '%s' "$fb"
  fi
}

# _bebop_mcp_config <profile> — echo the profile's mcp.json path (thin wrapper over
# _bebop_profile_dir; kept for callers that only need the --mcp-config argument).
_bebop_mcp_config() {
  printf '%s/mcp.json' "$(_bebop_profile_dir "${1:-team}")"
}

# Shared launch preamble: verify the pack, resolve mode, export shim env + telemetry.
# Sets globals _BT_MODE, _BT_AGENTS_JSON, _BT_ORCH_PROMPT for the caller. Returns
# non-zero (with a message) if the pack or shim isn't usable.
_bebop_team_prep() {
  if [ ! -x "$AGENTPACK_HOME/bin/agentops" ]; then
    echo "bebop team: agent pack not found at $AGENTPACK_HOME (set AGENTPACK_HOME)" >&2
    return 1
  fi
  _BT_MODE="$(_bebop_agentops mode 2>/dev/null)" || { echo "bebop team: agentops mode failed" >&2; return 1; }
  _BT_AGENTS_JSON="$(_bebop_agentops agents-json 2>/dev/null)" || { echo "bebop team: agentops agents-json failed" >&2; return 1; }
  _BT_ORCH_PROMPT="$(_bebop_agentops orch-prompt 2>/dev/null)" || { echo "bebop team: agentops orch-prompt failed" >&2; return 1; }
  # Shim env (constraint #6: frontier via shim). Telemetry env present from day 1
  # (Phase 3 wires the sinks); AGENTPACK_HOME so the orchestrator can find contracts/dials.
  export ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy
  export AGENTPACK_HOME
  return 0
}

unalias team 2>/dev/null
bebop_team() {
  _bebop_team_prep || return 1
  local orch="${AGENTPACK_ORCHESTRATOR_MODEL:-claude-opus-4.8}"
  [ "$_BT_MODE" = DEGRADED ] && echo "bebop team: MODE=DEGRADED (GPU down) — leafs on frontier by affinity" >&2
  # Parent = frontier planner on the shim. ANTHROPIC_SMALL_FAST_MODEL matches the parent
  # model so background/title calls don't force a local swap (S1 finding). The pack is
  # injected via --agents; per-agent `model:` routes each leaf turn (proven in S1).
  # Phase 2: profile fence. CLAUDE_CONFIG_DIR re-homes the config layer to profiles/team/
  # (its own skills/ + settings.json OTel+kanban hooks) and --strict-mcp-config with the
  # profile's empty mcp.json drops the dead gridctl + qmd/pvectl schemas. Together this is
  # the measured cold-session saving (54,311 -> ~48.5k). --agents/--append-system-prompt
  # inject the pack + orchestrator prompt as before (rule 1: routing unchanged).
  local dir; dir="$(_bebop_profile_dir team)"
  CLAUDE_CONFIG_DIR="$dir" \
  ANTHROPIC_MODEL="$orch" ANTHROPIC_SMALL_FAST_MODEL="$orch" \
  claude --model "$orch" --strict-mcp-config --mcp-config "$dir/mcp.json" \
    --agents "$_BT_AGENTS_JSON" \
    --append-system-prompt "$_BT_ORCH_PROMPT" "$@"
}

unalias team-local 2>/dev/null
bebop_team_local() {
  _bebop_team_prep || return 1
  # The DESTINATION config: the orchestrator itself is the local model (thinking ON, per
  # the 11.2 finding that thinking fixes multi-step planning). Available from day 1 so its
  # success rate is measured alongside the opus orchestrator, not guessed. Frontier
  # specialists (judge/architect/rescuer) still resolve to Compass via --agents.
  local orch="${AGENTPACK_LOCAL_MODEL:-qwen3.6-35b-a3b}"
  local ctx="${AGENTPACK_LOCAL_CTX:-131072}"
  [ "$_BT_MODE" = DEGRADED ] && echo "bebop team-local: MODE=DEGRADED — local orchestrator unavailable; using $orch anyway (GPU down: expect failure)" >&2
  echo "bebop team-local: orchestrator=$orch (thinking on) — baseline measurement, failure is acceptable" >&2
  # Phase 2: profile fence — same team profile as `bebop team` (CLAUDE_CONFIG_DIR + strict-MCP).
  local dir; dir="$(_bebop_profile_dir team)"
  CLAUDE_CONFIG_DIR="$dir" \
  ANTHROPIC_MODEL="$orch" ANTHROPIC_SMALL_FAST_MODEL="$orch" \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="$ctx" MAX_THINKING_TOKENS=8000 \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000 \
  claude --model "$orch" --strict-mcp-config --mcp-config "$dir/mcp.json" \
    --agents "$_BT_AGENTS_JSON" \
    --append-system-prompt "$_BT_ORCH_PROMPT" "$@"
}

# bebop ai-ops [claude args...] — the DIRECTOR entrypoint (Phase 4). Runs the `ai-ops`
# role on the MAIN THREAD (its body promoted to --append-system-prompt), so a human can
# drive the fleet director directly without a `bebop team` orchestrator hop. Unlike
# `bebop ask`, ai-ops is NOT read-only: it mutates through the guarded ops skills and can
# dispatch investigator/executor via the Task tool, so the whole agent pack is injected
# via --agents (same JSON as `bebop team`) and there is NO plan-mode lock. The session is
# fenced to profiles/ai-ops/ (7 ops skills, empty mcp.json) via CLAUDE_CONFIG_DIR +
# --strict-mcp-config. Model resolves by ops affinity (LOCAL -> qwen35; DEGRADED -> opus).
unalias ai-ops 2>/dev/null
bebop_ai_ops() {
  if [ ! -x "$AGENTPACK_HOME/bin/agentops" ]; then
    echo "bebop ai-ops: agent pack not found at $AGENTPACK_HOME (set AGENTPACK_HOME)" >&2
    return 1
  fi
  local mode model prompt agents_json dir
  mode="$(_bebop_agentops mode 2>/dev/null)" || { echo "bebop ai-ops: agentops mode failed" >&2; return 1; }
  model="$(_bebop_agentops model ai-ops 2>/dev/null)" || { echo "bebop ai-ops: agentops model failed" >&2; return 1; }
  # Phase 8 — resolve the director's worker runtime through the SIGNED local runtime
  # registry: the executable command + model come from the rendered runtime-registry.json,
  # gated by record_hash re-verification (tamper refusal) and the alias-rejection readiness
  # check. Fail closed: refuse to launch if the registry refuses the ai-ops record.
  local runtime_line
  runtime_line="$(_bebop_agentops runtime ai-ops 2>/dev/null)" || {
    echo "bebop ai-ops: signed runtime registry REFUSED ai-ops — refusing to launch" >&2; return 1; }
  echo "bebop ai-ops: registry-resolved runtime -> $(printf '%s' "$runtime_line" | awk '/^launch role=/{print}')" >&2
  agents_json="$(_bebop_agentops agents-json 2>/dev/null)" || { echo "bebop ai-ops: agentops agents-json failed" >&2; return 1; }
  [ "$mode" = DEGRADED ] && echo "bebop ai-ops: MODE=DEGRADED (GPU down) — director on frontier (opus) by ops affinity" >&2

  # Phase 7 — mint the job's trace identity ONCE, at the top of the director job, and export
  # it so every downstream process (agentops emit, sdd-run.sh, the Wiggum run it launches)
  # stamps the SAME ids. Respect an already-set value so a caller/CI can pin the trace. The
  # contract_id is the human-legible business key; the trace_id is W3C format (32 lowercase
  # hex = 16 random bytes) for OTel correlation; WIGGUM_FEATURE is the feature slug.
  if [ -z "${AGENTPACK_CONTRACT_ID:-}" ]; then
    local _ts _rnd
    _ts="$(date +%Y%m%d-%H%M%S)"
    _rnd="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    export AGENTPACK_CONTRACT_ID="aiops-${_ts}-${_rnd:-0000}"
  fi
  if [ -z "${AGENTPACK_TRACE_ID:-}" ]; then
    export AGENTPACK_TRACE_ID="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  export WIGGUM_FEATURE="${WIGGUM_FEATURE:-default}"
  # Phase 4 — light the live NATS sink for this job. The broker's client port is the
  # registry's (rendered agentpack.ports.env: AGENTPACK_NATS_URL=127.0.0.1:5222). Exported
  # ONLY here at the launch surface (never in agentpack.conf), so `agentops emit` outside a
  # director job — with AGENTPACK_NATS_URL unset — is byte-identical to pre-Phase-4.
  if [ -z "${AGENTPACK_NATS_URL:-}" ]; then
    _agentpack_ports_env="${AGENTPACK_FLEET_CONFIG_HOME:-/root/fleet-config}/rendered/agent-pack/agentpack.ports.env"
    if [ -r "$_agentpack_ports_env" ]; then
      export AGENTPACK_NATS_URL="$(awk -F= '/^AGENTPACK_NATS_URL=/{print $2; exit}' "$_agentpack_ports_env")"
    fi
    export AGENTPACK_NATS_URL="${AGENTPACK_NATS_URL:-127.0.0.1:5222}"
  fi
  echo "bebop ai-ops: contract_id=$AGENTPACK_CONTRACT_ID trace_id=$AGENTPACK_TRACE_ID feature=$WIGGUM_FEATURE nats=$AGENTPACK_NATS_URL" >&2
  # Announce the job on every sink so the trace has a head event even if nothing else emits.
  "$AGENTPACK_HOME/bin/agentops" emit job_start agent=ai-ops task=director model="$model" \
    >/dev/null 2>&1 || true

  # Shim env (frontier via 127.0.0.1:8088); local ctx so Claude Code auto-compacts before
  # the shim overflow. Match SMALL_FAST to the director model so no local swap for titles.
  export ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy
  export ANTHROPIC_MODEL="$model" ANTHROPIC_SMALL_FAST_MODEL="$model"
  export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${AGENTPACK_LOCAL_CTX:-131072}"
  export AGENTPACK_HOME
  # Profile fence: CLAUDE_CONFIG_DIR re-homes the config layer to profiles/ai-ops/ (its 7
  # ops skills + settings.json OTel+kanban hooks); strict-MCP + the profile's empty mcp.json
  # loads no MCP servers. --agents injects the pack so the director can Task-dispatch leafs.
  dir="$(_bebop_profile_dir ai-ops)"
  CLAUDE_CONFIG_DIR="$dir" \
  claude --model "$model" --strict-mcp-config --mcp-config "$dir/mcp.json" \
    --agents "$agents_json" \
    --append-system-prompt "$prompt" "$@"
}

# bebop spec [claude args...] — the SDD entrypoint (Phase 5). Runs the `spec` role on the
# MAIN THREAD (its body promoted to --append-system-prompt) so a human — or `ai-ops` handing
# off feature work — can author Spec Kit artifacts (spec.md/plan.md/tasks.md) directly. The
# session is fenced to profiles/spec/ (EXACTLY the ten speckit-* skills, empty mcp.json) via
# CLAUDE_CONFIG_DIR + --strict-mcp-config. The ten skills are NOT preloaded (that would cost
# ~33k tokens); the role reaches them on demand through the `Skill` tool, which is safe by
# construction because the profile fences the session to nothing else. Model resolves to the
# frontier model while dials.json keeps the spec class at frontier-planned (spec authoring is
# decomposition — 12.1's one don't-hand-to-local task); it fades when a human fades the dial.
unalias spec 2>/dev/null
bebop_spec() {
  if [ ! -x "$AGENTPACK_HOME/bin/agentops" ]; then
    echo "bebop spec: agent pack not found at $AGENTPACK_HOME (set AGENTPACK_HOME)" >&2
    return 1
  fi
  local mode model prompt dir
  mode="$(_bebop_agentops mode 2>/dev/null)" || { echo "bebop spec: agentops mode failed" >&2; return 1; }
  model="$(_bebop_agentops model spec 2>/dev/null)" || { echo "bebop spec: agentops model failed" >&2; return 1; }
  prompt="$(_bebop_agentops ask-prompt spec 2>/dev/null)" || { echo "bebop spec: agentops ask-prompt failed" >&2; return 1; }
  local dial; dial="$(_bebop_agentops dial spec 2>/dev/null)" || dial=frontier-planned
  echo "bebop spec: spec class dial=$dial — authoring on $model (frontier while frontier-planned)" >&2

  # Shim env (frontier via 127.0.0.1:8088); local ctx so Claude Code auto-compacts before
  # the shim overflow. Match SMALL_FAST to the spec model so no local swap for titles.
  export ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy
  export ANTHROPIC_MODEL="$model" ANTHROPIC_SMALL_FAST_MODEL="$model"
  export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${AGENTPACK_LOCAL_CTX:-131072}"
  export AGENTPACK_HOME
  # Profile fence: CLAUDE_CONFIG_DIR re-homes the config layer to profiles/spec/ (its ten
  # speckit-* skills + settings.json OTel+kanban hooks); strict-MCP + the profile's empty
  # mcp.json loads no MCP servers. No --agents: spec is a leaf author, not an orchestrator;
  # the Skill tool (from the role frontmatter's allowlist) reaches the ten skills on demand.
  dir="$(_bebop_profile_dir spec)"
  CLAUDE_CONFIG_DIR="$dir" \
  claude --model "$model" --strict-mcp-config --mcp-config "$dir/mcp.json" \
    --append-system-prompt "$prompt" "$@"
}

# bebop wiggum-proposer [claude args...] — the Wiggum PROPOSER entrypoint (Phase 6). This is
# what `WIGGUM_PROPOSER=bebop:wiggum-proposer` resolves to: Wiggum's proposer.sh sources this
# file and calls `bebop wiggum-proposer -p "<phase prompt>" --dangerously-skip-permissions
# --verbose [--output-format stream-json]`. It runs a SINGLE model (executor's ops-affinity
# model: LOCAL -> qwen35; DEGRADED -> opus) fenced to profiles/wiggum-proposer/ — an executor
# toolbelt (Read/Grep/Glob/Edit/Write/Bash), NO speckit-* skills (that lives in the `spec`
# profile), and NO MCP (strict-MCP + empty mcp.json).
#
# CRITICAL nesting rule: NO --agents here. The proposer is a leaf that compiles an
# already-authored spec; it must never launch an agent tree inside a proposer pass (that
# would nest Wiggum's own critic gate under a second orchestrator). Single model, scoped
# profile, executor tools — nothing else. See lib/ladder.md (Wiggum critic ≡ pack `judge`).
#
# Run-native audit: when launched by Wiggum's proposer.sh (which exports WIGGUM_EVENTS), this
# entrypoint records TWO run-native proofs on the run's OWN events.jsonl — so "no speckit-*, no
# MCP" is provable from the run itself, not an out-of-band CLI call, and NOT from /root/wiggum
# (Wiggum's tap stays stock):
#   (1) proposer_profile     — the fence this launcher IMPOSES (allowed_tools, on-disk skills,
#                              mcp_servers from the profile dir). What the agent pack GRANTS.
#   (2) proposer_agent_init  — the fence Claude Code REPORTS it initialized with, parsed from
#                              Claude's own authoritative `system/init` stream-json line: the
#                              FULL tools/skills/mcp_servers/slash_commands lists (not a count).
#                              Proves speckit-*/MCP were UNAVAILABLE and reconciles tools=27
#                              (Claude's built-in registry) against the 6-tool executor
#                              allowlist. Also dropped as run-dir/agent-init.json for grounding.
unalias wiggum-proposer 2>/dev/null
bebop_wiggum_proposer() {
  if [ ! -x "$AGENTPACK_HOME/bin/agentops" ]; then
    echo "bebop wiggum-proposer: agent pack not found at $AGENTPACK_HOME (set AGENTPACK_HOME)" >&2
    return 1
  fi
  local mode model tools dir
  mode="$(_bebop_agentops mode 2>/dev/null)" || { echo "bebop wiggum-proposer: agentops mode failed" >&2; return 1; }
  # The proposer is an executor by role: same ops-affinity model resolution.
  model="$(_bebop_agentops model executor 2>/dev/null)" || { echo "bebop wiggum-proposer: agentops model failed" >&2; return 1; }
  tools="$(_bebop_agentops tools executor 2>/dev/null)"   # executor toolbelt allowlist
  [ "$mode" = DEGRADED ] && echo "bebop wiggum-proposer: MODE=DEGRADED (GPU down) — proposer on frontier (opus) by ops affinity" >&2

  # Shim env (frontier via 127.0.0.1:8088); local ctx so Claude Code auto-compacts before
  # the shim overflow. Match SMALL_FAST to the proposer model so no local swap for titles.
  export ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy
  export ANTHROPIC_MODEL="$model" ANTHROPIC_SMALL_FAST_MODEL="$model"
  export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${AGENTPACK_LOCAL_CTX:-131072}"
  export AGENTPACK_HOME
  # Profile fence: CLAUDE_CONFIG_DIR re-homes the config layer to profiles/wiggum-proposer/
  # (empty skills/ — no speckit-*, its settings.json OTel+kanban hooks); strict-MCP + the
  # profile's empty mcp.json loads no MCP servers. NO --agents (no nested tree). The executor
  # tool allowlist bounds the session to the executor toolbelt.
  dir="$(_bebop_profile_dir wiggum-proposer)"

  # Run-native fence manifest: when Wiggum's proposer.sh launched us it exported
  # WIGGUM_EVENTS (the active run's events.jsonl). Append a `proposer_profile` event
  # naming the EXACT fence this launch imposes — allowed tools, on-disk skills, MCP
  # servers — so a run is auditable ("no speckit-*, no MCP") from its OWN event stream
  # rather than an out-of-band CLI call. This is the agent-pack launcher recording what
  # it grants; it does NOT touch /root/wiggum (Wiggum's own tap is unmodified).
  if [ -n "${WIGGUM_EVENTS:-}" ]; then
    AP_WP_DIR="$dir" AP_WP_TOOLS="$tools" AP_WP_MODEL="$model" \
    AP_WP_EVENTS="$WIGGUM_EVENTS" AP_WP_RUN="${WIGGUM_RUN_ID:-}" \
    AP_WP_TASK="${WIGGUM_TASK:-}" AP_WP_BACKEND="${WIGGUM_BACKEND_LABEL:-bebop:wiggum-proposer}" \
    python3 - <<'PYWP' 2>/dev/null || true
import json, os, time, glob
d = os.environ["AP_WP_DIR"]
skills = sorted(
    os.path.basename(p) for p in glob.glob(os.path.join(d, "skills", "*"))
    if os.path.isdir(p) or p.endswith(".md")
)
mcp_servers = []
try:
    with open(os.path.join(d, "mcp.json")) as fh:
        mcp_servers = sorted((json.load(fh).get("mcpServers") or {}).keys())
except Exception:
    pass
tools = (os.environ.get("AP_WP_TOOLS") or "").split()
rec = {
    "ts": "%f" % time.time(),
    "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "event": "proposer_profile",
    "run_id": os.environ.get("AP_WP_RUN", ""),
    "task": os.environ.get("AP_WP_TASK", ""),
    "backend": os.environ.get("AP_WP_BACKEND", ""),
    "profile": "wiggum-proposer",
    "profile_dir": d,
    "model": os.environ.get("AP_WP_MODEL", ""),
    "allowed_tools": ",".join(tools),
    "n_allowed_tools": str(len(tools)),
    "skills": ",".join(skills),
    "n_skills": str(len(skills)),
    "n_speckit_skills": str(sum(1 for s in skills if s.startswith("speckit"))),
    "mcp_servers": ",".join(mcp_servers),
    "n_mcp_servers": str(len(mcp_servers)),
    "strict_mcp": "true",
    "nested_tree": "false",
}
with open(os.environ["AP_WP_EVENTS"], "a") as fh:
    fh.write(json.dumps(rec) + "\n")
PYWP
    unset AP_WP_DIR AP_WP_TOOLS AP_WP_MODEL AP_WP_EVENTS AP_WP_RUN AP_WP_TASK AP_WP_BACKEND
  fi

  # Run-native init inventory (C7 proof — agent-pack side; /root/wiggum untouched).
  # Claude Code's OWN `system/init` stream-json line is the authoritative record of
  # every tool, skill, MCP server and slash command the session actually initialized
  # with. Stock Wiggum's tap keeps only len(tools) as a count, which cannot prove that
  # NO speckit-* skill and NO MCP tool were *available* (only which were invoked). When
  # Wiggum drives us in stream-json mode (it exports WIGGUM_EVENTS and passes
  # --output-format stream-json), we tee the raw stream to the run dir, then parse that
  # init line and (a) append a `proposer_agent_init` event carrying the FULL
  # tools/skills/mcp_servers/slash_commands lists to the run's OWN events.jsonl, and
  # (b) drop a small agent-init.json beside it — so "no speckit-*, no MCP available"
  # and the tools=27 registry-vs-allowlist reconciliation are provable from the run
  # path itself, not an out-of-band CLI call and not a copied file.
  local _wp_stream=0 _wp_a
  for _wp_a in "$@"; do [ "$_wp_a" = "stream-json" ] && _wp_stream=1; done
  # word-split $tools intentionally (space-separated allowlist).
  # shellcheck disable=SC2086
  if [ -n "${WIGGUM_EVENTS:-}" ] && [ "$_wp_stream" = 1 ]; then
    local _wp_rundir _wp_raw _wp_rc
    _wp_rundir="$(dirname "$WIGGUM_EVENTS")"
    _wp_raw="$_wp_rundir/proposer-raw-stream.jsonl"
    CLAUDE_CONFIG_DIR="$dir" \
    claude --model "$model" --strict-mcp-config --mcp-config "$dir/mcp.json" \
      --allowedTools $tools "$@" | tee -a "$_wp_raw"
    _wp_rc=${PIPESTATUS[0]}
    AP_WP_RAW="$_wp_raw" AP_WP_EVENTS="$WIGGUM_EVENTS" AP_WP_RUNDIR="$_wp_rundir" \
    AP_WP_RUN="${WIGGUM_RUN_ID:-}" AP_WP_TASK="${WIGGUM_TASK:-}" \
    AP_WP_BACKEND="${WIGGUM_BACKEND_LABEL:-bebop:wiggum-proposer}" AP_WP_TOOLS="$tools" \
    AP_WP_MODEL="$model" python3 - <<'PYINIT' 2>/dev/null || true
import json, os, time
raw = os.environ["AP_WP_RAW"]
init = None
try:
    with open(raw, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("type") == "system" and o.get("subtype") == "init":
                init = o
                break
except Exception:
    init = None
if init is not None:
    tools = list(init.get("tools", []) or [])
    skills = list(init.get("skills", []) or [])
    mcp_servers = list(init.get("mcp_servers", []) or [])
    slash = list(init.get("slash_commands", []) or [])
    def _speckit(seq):
        return sorted(x for x in seq if "speckit" in str(x).lower())
    def _mcp(seq):
        return sorted(x for x in seq if str(x).startswith("mcp__"))
    allow = (os.environ.get("AP_WP_TOOLS") or "").split()
    rec = {
        "ts": "%f" % time.time(),
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "event": "proposer_agent_init",
        "run_id": os.environ.get("AP_WP_RUN", ""),
        "task": os.environ.get("AP_WP_TASK", ""),
        "backend": os.environ.get("AP_WP_BACKEND", ""),
        "source": "claude-code system/init stream-json line (authoritative)",
        "model": init.get("model") or os.environ.get("AP_WP_MODEL", ""),
        "permissionMode": init.get("permissionMode", ""),
        # --allowedTools is the PERMISSION fence (6 executor tools); `tools` is Claude
        # Code's built-in tool REGISTRY (Task/Bash/Cron*/Web*/…) — neither contains any
        # mcp__* or speckit-* entry. This is the tools=27 reconciliation.
        "allowed_tools": ",".join(allow),
        "n_allowed_tools": str(len(allow)),
        "tools": ",".join(map(str, tools)),
        "n_tools": str(len(tools)),
        "mcp_tools": ",".join(_mcp(tools)),
        "n_mcp_tools": str(len(_mcp(tools))),
        "mcp_servers": ",".join(map(str, mcp_servers)),
        "n_mcp_servers": str(len(mcp_servers)),
        "skills": ",".join(map(str, skills)),
        "n_skills": str(len(skills)),
        "speckit_skills": ",".join(_speckit(skills)),
        "n_speckit_skills": str(len(_speckit(skills))),
        "n_speckit_slash_commands": str(len(_speckit(slash))),
        "n_slash_commands": str(len(slash)),
    }
    line = json.dumps(rec)
    with open(os.environ["AP_WP_EVENTS"], "a") as fh:
        fh.write(line + "\n")
    # Small, fully-excerptable proof file at the run path (same JSON as the event
    # just appended to events.jsonl) so the grounding snapshot can show it whole.
    with open(os.path.join(os.environ["AP_WP_RUNDIR"], "agent-init.json"), "w") as fh:
        fh.write(json.dumps(rec, indent=2) + "\n")
PYINIT
    unset AP_WP_RAW AP_WP_EVENTS AP_WP_RUNDIR AP_WP_RUN AP_WP_TASK AP_WP_BACKEND AP_WP_TOOLS AP_WP_MODEL
    return "$_wp_rc"
  fi
  CLAUDE_CONFIG_DIR="$dir" \
  claude --model "$model" --strict-mcp-config --mcp-config "$dir/mcp.json" \
    --allowedTools $tools "$@"
}

# bebop ask <role> "question" — direct read-only line to a leaf, NO orchestrator hop
# (spike S1b variant A: role body promoted to the main-thread system prompt). Model is
# resolved by the same LOCAL/DEGRADED logic as the tree. HARD read-only: plan permission
# mode (harness-enforced regardless of backend — proven to block Bash mutations) + the
# role's own read-only tool allowlist. `ask` can never mutate, whatever the model decides.
# Roles are the read-only ones: investigator (fleet/AIOps) and librarian (recall/docs).
unalias ask 2>/dev/null
bebop_ask() {
  if [ ! -x "$AGENTPACK_HOME/bin/agentops" ]; then
    echo "bebop ask: agent pack not found at $AGENTPACK_HOME (set AGENTPACK_HOME)" >&2
    return 1
  fi
  local role="${1:-}" ; shift || true
  case "$role" in
    investigator|librarian) : ;;
    "" ) echo "usage: bebop ask <investigator|librarian> \"question\"" >&2; return 2 ;;
    executor|scribe|judge|architect|rescuer)
      echo "bebop ask: '$role' is not a read-only role. 'ask' is question-only." >&2
      echo "  For work that changes state or produces artifacts, use: bebop team" >&2
      return 2 ;;
    * ) echo "bebop ask: unknown role '$role' (read-only roles: investigator, librarian)" >&2; return 2 ;;
  esac
  local question="$*"
  [ -z "$question" ] && { echo "bebop ask: no question given" >&2; return 2; }

  local model tools prompt
  model="$(_bebop_agentops model "$role" 2>/dev/null)" || { echo "bebop ask: agentops model failed" >&2; return 1; }
  tools="$(_bebop_agentops tools "$role" 2>/dev/null)"       # role's read-only allowlist
  prompt="$(_bebop_agentops ask-prompt "$role" 2>/dev/null)" || { echo "bebop ask: agentops ask-prompt failed" >&2; return 1; }

  export ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy
  export ANTHROPIC_MODEL="$model" ANTHROPIC_SMALL_FAST_MODEL="$model"
  export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${AGENTPACK_LOCAL_CTX:-131072}"
  # Phase 2: profile fence. Map the read-only role to its profile (investigator -> ai-ops,
  # librarian -> librarian) and route through it via CLAUDE_CONFIG_DIR + --strict-mcp-config
  # with the profile's empty mcp.json, so no MCP schemas load into the ask session.
  local askprofile dir
  case "$role" in investigator) askprofile=ai-ops ;; *) askprofile="$role" ;; esac
  dir="$(_bebop_profile_dir "$askprofile")"
  export CLAUDE_CONFIG_DIR="$dir"
  # plan mode = hard read-only boundary (harness-enforced); allowlist = the role's tools.
  # word-split $tools intentionally (it's a space-separated allowlist).
  # shellcheck disable=SC2086
  claude -p "$question" --model "$model" --permission-mode plan \
    --strict-mcp-config --mcp-config "$dir/mcp.json" \
    --append-system-prompt "$prompt" --allowedTools $tools
}

# antares: one-shot text-in / text-out call to the local antares-1b (Granite-4.0)
# model via the fleet LiteLLM gateway (:4000). Deliberately NOT wired into an agent
# harness (pi/Claude Code): a 1B rambles under a big agent system-prompt+tools and
# runs into the output cap. This path sends a concise system prompt, NO tools, and
# just prints the reply. Usage:  antares -p "your prompt"   (or: antares "your prompt")
unalias antares 2>/dev/null
antares() {
  local prompt=""
  case "${1:-}" in
    -p|--prompt) shift; prompt="$*" ;;
    "" ) : ;;                       # no arg -> read stdin below
    * ) prompt="$*" ;;
  esac
  [ -z "$prompt" ] && prompt="$(cat)"   # allow: echo "..." | antares
  if [ -z "$prompt" ]; then
    echo "usage: antares -p \"your prompt\"   (or: antares \"your prompt\", or pipe via stdin)" >&2
    return 2
  fi

  local key
  key=$(grep -m1 '^LITELLM_MASTER_KEY=' /root/litellm/.env | cut -d= -f2)
  if [ -z "$key" ]; then
    echo "antares: could not read LITELLM_MASTER_KEY from /root/litellm/.env" >&2
    return 1
  fi

  # jq builds the request body so the prompt is safely JSON-escaped (no shell-quoting traps).
  local body
  body=$(jq -n --arg p "$prompt" '{
    model: "antares",
    messages: [
      {role:"system", content:"You are a concise assistant. Answer directly and stop."},
      {role:"user", content:$p}
    ],
    max_tokens: 2048,
    temperature: 0
  }')

  local resp
  resp=$(curl -s -m 120 http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "$body")

  # Print the reply; surface API errors instead of a silent empty line.
  echo "$resp" | jq -e -r '.choices[0].message.content' 2>/dev/null && return 0
  echo "antares: request failed ->" >&2
  echo "$resp" | jq -r '.error.message // .message // .' 2>/dev/null >&2 || echo "$resp" >&2
  return 1
}
