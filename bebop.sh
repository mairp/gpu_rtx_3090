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
# Cloud model on Compass STAGE (NOT llama-swap — via the shim's OPENAI_MODELS path):
#   bebop gpt        -> Compass gpt-5.5  (cloud reasoning model; alias: gpt-5.5)
#   bebop qwen-fp4   -> Qwen3.6-27B NVFP4  (only after Step 6 promotion; else falls back to 27B)
#   add "-think" for the reasoning variant, e.g.  bebop qwen-think / bebop qwen-big-think
#
# bebop v3 — the frontier-fading agent TREE (roadmap 12.1; opus plans, qwen executes):
#   bebop team [args...]        -> orchestrator (opus-4.8) + agent pack loaded; plan-first
#   bebop team-local [args...]  -> same tree, orchestrator = qwen35 (the destination config)
#   bebop ask <role> "q"        -> headless READ-ONLY leaf, no orchestrator hop (S1b)
#                                  roles: investigator (fleet/AIOps), librarian (recall/docs)
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
    [gpt]=98304               # shim routes gpt-5.5 via handle_qwen; no QWEN_CTX_MAP entry -> QWEN_CTX fallback (98304)
    [gpt-5.5]=98304          # so tell Claude Code the same window -> it auto-compacts before the shim's overflow 400
  )
  local sel=${1:-compass} think=
  # bebop v3 subcommands (Phase 2): the agent tree. Dispatch to their functions and
  # return — they own the whole arg tail. Single-model entrypoints below are unchanged.
  case "$sel" in
    team)       shift; bebop_team "$@"; return ;;
    team-local) shift; bebop_team_local "$@"; return ;;
    ask)        shift; bebop_ask "$@"; return ;;
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
  ANTHROPIC_MODEL="$orch" ANTHROPIC_SMALL_FAST_MODEL="$orch" \
  claude --model "$orch" --agents "$_BT_AGENTS_JSON" \
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
  ANTHROPIC_MODEL="$orch" ANTHROPIC_SMALL_FAST_MODEL="$orch" \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="$ctx" MAX_THINKING_TOKENS=8000 \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000 \
  claude --model "$orch" --agents "$_BT_AGENTS_JSON" \
    --append-system-prompt "$_BT_ORCH_PROMPT" "$@"
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
  # plan mode = hard read-only boundary (harness-enforced); allowlist = the role's tools.
  # word-split $tools intentionally (it's a space-separated allowlist).
  # shellcheck disable=SC2086
  claude -p "$question" --model "$model" --permission-mode plan \
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
