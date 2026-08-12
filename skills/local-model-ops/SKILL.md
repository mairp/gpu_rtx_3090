---
name: local-model-ops
description: >-
  Hardware-aware guidance for running local Qwen3.6 and Muse models on the RTX 3090
  eGPU (llama-swap on this host) - which model to pick, when to think, when to
  escalate to gpt-5/claude, and what the serving limits are. Use when asked
  "which local model should I use", "run this on qwen", "why is the local model
  slow / truncated / swapping", "qwen vs muse", or before starting a long
  local-model job (bebop qwen / bebop muse / pi / OpenClaw locals).
---

# Local model ops — Qwen3.6 and Muse on the RTX 3090 (24 GB)

Serving path: consumer -> cc-compass-shim :8088 (bebop/Claude Code only) ->
LiteLLM :4000 -> llama-swap :8081 -> llama.cpp on the 3090. All numbers below
were measured in /root/benchmark_models (2026-07-11 tuning pass).

## Model choice

- `qwen-auto` (via `bebop auto` or LiteLLM model `qwen-auto`): let the router
  decide - hard-reasoning cues go to gpt-5, big jobs (>~20k-token prompt or
  max_tokens >= 4000) go to Muse, everything else sticks to whichever local
  is already loaded (never forces a swap; idle default 27B). Good default when
  you do not want to think about routing. Opt-in alias only - the concrete
  model names below behave exactly as before.
- `qwen3.6-27b` (dense Q4_K_M): default for code-heavy, careful editing work.
  ~57-65 tok/s decode with MTP spec-decode.
- `muse-glimmer-30b` (Muse MoE, I-Compact): throughput and long-context work.
  ~145 tok/s decode, ~2.5x faster than the 27B at EQUAL quality (both 18/20 on
  the house battery, same failures). Prefer it when output volume dominates.
- Only ONE model fits in 24 GB. Switching models (including any small/fast
  model that differs from the active one) forces a full reload from disk -
  up to minutes for Muse. One model per session; do not ping-pong.
- Idle TTL is 900 s: after 15 min unused the model unloads and the next call
  pays a cold load.

## Reasoning / escalation

- Both locals FAIL hard multi-step math and strict output-length tasks with
  thinking OFF. Measured 2026-07-11: thinking ON with a small (~4k) budget
  FIXES exactly those failures on the 27B (3/3 repeats, tool-calls stay
  clean) - use `bebop qwen-think` for math / strict-format work instead of
  giving up on local. Thinking costs context-window and TTFT, so keep it off
  for routine code/tool loops.
- Genuinely hard reasoning (multi-step architecture, novel proofs, long
  chains): escalate to `bebop compass` (gpt-5/claude via Compass). That is
  the lever - not a bigger local model.

## Serving limits (owner: /root/llama-swap/config.yaml)

- Context (raised 2026-07-12; both GGUFs trained for 262144): Qwen 27B serves
  -c 98304, Muse serves -c 131072 (its hybrid attention makes big KV cheap;
  the 27B at 128k was too close to the VRAM ceiling). KV q8_0. The shim 400s
  when a prompt overflows the per-model window (QWEN_CTX_MAP) - do not
  silently retry with a bigger number; trim, or route big jobs to Muse.
- bebop exports CLAUDE_CODE_MAX_CONTEXT_TOKENS (qwen 98304, muse/auto 131072;
  deprecated qwen-big/qwen35 aliases also 131072), so Claude Code auto-compacts before the shim's 400. A bebop
  session that still hits the 400 means the env is missing (stale shell -
  re-source bebop.sh). A fresh bebop session's fixed overhead is ~29k tokens.
- Output ceiling: --n-predict 16384 server-side; shim QWEN_MAX_OUTPUT 16384;
  bebop CLAUDE_CODE_MAX_OUTPUT_TOKENS 16000. A generation stopping near 16k is
  the real ceiling, not a bug. (Before 2026-07-11 the cap was 4096.)
- Samplers: server defaults are temp 0.7, top-p 0.8, top-k 20 (Qwen vendor
  guidance for non-thinking use; beat both temp-0 and the old unset defaults
  on the house battery, 2026-07-11). Requests that set their own
  temperature/top_p override them; omit samplers unless you have a reason.
- Prefix caching works (llama-server longest-common-prefix reuse, single
  slot): turn 2..N of a session re-prefills only the appended tail. A request
  from ANOTHER consumer in between evicts the cached prefix - expect a full
  re-prefill after interleaved fleet traffic.

## HARD RULES

- Check or free VRAM and power the eGPU ONLY via the gpu-ops / fleet-control
  skills (gpu-status.sh, gpu-safe-shutdown.sh, gpu-power-up.sh). Never
  hand-roll docker stop, nvidia-smi kills, or PCIe pokes.
- Serving-flag changes go through /root/benchmark_models first, then are
  promoted to /root/llama-swap/config.yaml (git-tracked) - never edit flags
  live without a bench + a .bak.
- The llama-swap server is SHARED (duby, linky, havan, mira, pi, OpenClaw).
  Long saturating jobs serialize everyone else; batch work off-hours.
- Keep arguments literal - no command substitution, backticks, or variables
  in commands (OpenClaw exec-approval trap). No emojis.

## Notes

- Repo: /root/gpu_rtx_3090 (this skill lives here; symlinked into
  /root/.claude/skills). Sibling skills: gpu-ops (power/VRAM), fleet-control
  (whole-stack), qmd-recall (fleet memory).
- Benchmark provenance: /root/benchmark_models/results/ + qmd docs
  local-arc-inference-qwen3 and qwen3.6-model-benchmark.
