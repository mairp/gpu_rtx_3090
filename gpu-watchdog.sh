#!/usr/bin/env bash
# gpu-watchdog.sh — roadmap 12.1 Phase 0 S3.
#
# One poll of RTX 3090 health during agent runs. On Xid-79 "fallen off the bus"
# wedge or an unresponsive driver it:
#   (a) flips the degraded flag  /run/agentops/gpu-degraded  (with a reason line),
#   (b) raises an alert by writing a Prometheus textfile metric
#       agentops_gpu_degraded=1 into the node-exporter textfile collector, which
#       the existing NVIDIA alert path (AgentOpsGPUDegraded rule) picks up.
#
# For the Xid-79 wedge it does NOT attempt recovery: a wedge needs an OS reboot
# (detach/rescan queues onto the stuck thunderbolt kworker and hangs — see
# gpu-status.sh / lib.sh). That is a human call; the watchdog only observes,
# flags, and alerts.
#
# H1 (roadmap 12.1 v4): it ALSO detects a quieter failure the device-health checks
# miss — CPU-fallback / stale-CUDA. After a bus re-enumeration the container's CUDA
# handles go stale and llama.cpp silently serves on CPU (GPU reads healthy, VRAM
# ~1 MiB, 35B MoE ~13 tok/s). Predicate: llama-swap reports a model 'ready' AND
# VRAM below the floor (or no llama-server compute app) => degraded reason=cpu-fallback.
# Unlike a wedge, the sanctioned fix is REVERSIBLE — a one-shot
# `docker compose up -d --force-recreate` (re-injects the nvidia device → fresh CUDA
# handles; a child respawn does NOT fix it, see [[llama-swap-cpu-fallback-stale-cuda]]).
# That remediation is OPT-IN and bounded (one attempt/episode, then escalate to human):
# the shared serving is touched only when a human turns it on, per the executor rule.
#
# The orchestrator's dispatch prompt reads /run/agentops/gpu-degraded: present =>
# route leaf work to Compass (DEGRADED mode) and say so. reason=cpu-fallback is
# consumed identically to any other degraded reason.
#
# Run once (systemd timer, every ~30s during agent runs) or by hand:
#   gpu-watchdog.sh                    # poll once, set/clear flag, emit metric
#   gpu-watchdog.sh --simulate         # force a generic degraded flag+metric (no GPU touch)
#   gpu-watchdog.sh --simulate-cpu-fallback # force a cpu-fallback flag+metric (no GPU touch)
#   gpu-watchdog.sh --clear            # clear a flag (e.g. after verified recovery)
#   gpu-watchdog.sh --status           # print current flag state, touch nothing
#
# Env:
#   AGENTOPS_CPU_FALLBACK_REMEDIATE=1  # opt in to the bounded one-shot recreate (default 0 = flag+alert only)
#   AGENTOPS_REMEDIATE_DRY_RUN=1       # print the recreate command, do not run it
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

FLAG_DIR="${AGENTOPS_RUN_DIR:-/run/agentops}"
FLAG="$FLAG_DIR/gpu-degraded"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
METRIC="$TEXTFILE_DIR/agentops_gpu.prom"

# H1 cpu-fallback config. Remediation is OFF by default: the shared serving is only
# ever touched when a human opts in (executor rule: confirm before changing shared
# GPU/serving state). When on, it is bounded to ONE recreate per degraded episode —
# a per-episode stamp file prevents the 30s timer from loop-recreating (which could
# mask the eGPU endurance fault).
COMPOSE_FILE="${LLAMA_SWAP_COMPOSE:-/root/llama-swap/docker-compose.yml}"
REMEDIATE="${AGENTOPS_CPU_FALLBACK_REMEDIATE:-0}"
REMEDIATE_DRY_RUN="${AGENTOPS_REMEDIATE_DRY_RUN:-0}"
REMEDIATE_STAMP="$FLAG_DIR/cpu-fallback-remediated"
REMEDIATE_SETTLE="${AGENTOPS_REMEDIATE_SETTLE:-60}"   # seconds to wait for VRAM to go resident

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Atomic write of the degraded metric (1 = degraded, 0 = healthy). reason label is
# free text; kept short and quoted for Prometheus.
emit_metric() {
  local val="$1" reason="${2:-}"
  [ -d "$TEXTFILE_DIR" ] || return 0   # collector not present on this host => skip
  local tmp; tmp="$(mktemp "$TEXTFILE_DIR/.agentops_gpu.XXXXXX")" || return 0
  {
    echo "# HELP agentops_gpu_degraded RTX 3090 degraded flag set by gpu-watchdog (1=degraded)."
    echo "# TYPE agentops_gpu_degraded gauge"
    if [ "$val" = 1 ]; then
      printf 'agentops_gpu_degraded{reason="%s"} 1\n' "${reason//\"/}"
    else
      echo "agentops_gpu_degraded 0"
    fi
  } > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$METRIC" || rm -f "$tmp"
}

set_flag() {
  local reason="$1"
  mkdir -p "$FLAG_DIR" 2>/dev/null || true
  # Preserve the original trip time if the flag already exists.
  if [ ! -e "$FLAG" ]; then
    { echo "degraded_since=$(now_iso)"; echo "reason=$reason"; } > "$FLAG"
  fi
  emit_metric 1 "$reason"
}

clear_flag() {
  rm -f "$FLAG" 2>/dev/null || true
  emit_metric 0
}

flag_reason() { [ -e "$FLAG" ] && sed -n 's/^reason=//p' "$FLAG" | head -1 || true; }

case "${1:-}" in
  --status)
    if [ -e "$FLAG" ]; then echo "DEGRADED"; cat "$FLAG"; else echo "OK (no flag)"; fi
    exit 0
    ;;
  --clear)
    clear_flag; echo "cleared $FLAG (+ metric agentops_gpu_degraded=0)"; exit 0
    ;;
  --simulate)
    set_flag "simulated-test"
    echo "SIMULATED degraded flag at $FLAG (+ metric=1). Clear with: $0 --clear"
    cat "$FLAG"
    exit 0
    ;;
  --simulate-cpu-fallback)
    set_flag "cpu-fallback"
    echo "SIMULATED cpu-fallback degraded flag at $FLAG (+ metric reason=cpu-fallback). Clear with: $0 --clear"
    cat "$FLAG"
    exit 0
    ;;
esac

# Bounded, opt-in, one-shot remediation for a cpu-fallback episode. Returns 0 if the
# GPU is resident afterwards, 1 otherwise (caller escalates to human). NEVER loops:
# the per-episode stamp is written before the attempt so a subsequent timer tick
# will not re-recreate. A child kill is explicitly NOT a remedy (respawn inherits the
# stale context) — only compose --force-recreate re-injects the device.
remediate_cpu_fallback() {
  if [ "$REMEDIATE" != 1 ]; then
    warn "cpu-fallback: auto-remediation OFF (AGENTOPS_CPU_FALLBACK_REMEDIATE=1 to enable). Flag+alert set; escalate to human."
    return 1
  fi
  if [ -e "$REMEDIATE_STAMP" ]; then
    warn "cpu-fallback: already remediated once this episode ($REMEDIATE_STAMP) and VRAM still not resident — NOT looping. Escalate to human."
    return 1
  fi
  command -v docker >/dev/null 2>&1 || { err "cpu-fallback: docker not found; cannot remediate. Escalate to human."; return 1; }
  local cmd="docker compose -f $COMPOSE_FILE up -d --force-recreate"
  if [ "$REMEDIATE_DRY_RUN" = 1 ]; then
    log "cpu-fallback DRY-RUN: would run: $cmd"
    return 1
  fi
  mkdir -p "$FLAG_DIR" 2>/dev/null || true
  echo "remediated_at=$(now_iso)" > "$REMEDIATE_STAMP"
  log "cpu-fallback: one-shot remediation → $cmd"
  # shellcheck disable=SC2086
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate >/dev/null 2>&1 || warn "compose recreate returned nonzero"
  # Wait up to REMEDIATE_SETTLE for VRAM to go resident.
  local t0 now vram; t0=$(date +%s)
  while :; do
    vram="$(gpu_vram_used_mib || echo 0)"
    if [ "${vram:-0}" -ge 5000 ] 2>/dev/null; then
      ok "cpu-fallback: VRAM resident again (${vram} MiB) after recreate."
      return 0
    fi
    now=$(date +%s); [ $((now - t0)) -ge "$REMEDIATE_SETTLE" ] && break
    sleep 5
  done
  err "cpu-fallback: VRAM still not resident (${vram:-?} MiB) ${REMEDIATE_SETTLE}s after recreate. NOT retrying — escalate to human (possible eGPU endurance fault)."
  return 1
}

# --- real poll ------------------------------------------------------------
# Case 1: the Xid-79 wedge — enumerated but unresponsive. Only a reboot clears it,
# so the flag must persist (do not auto-clear a wedge). /run is tmpfs => a reboot
# clears the flag naturally once the host comes back healthy.
if gpu_off_bus_wedge; then
  set_flag "xid79-off-bus-wedge"
  err "GPU FALLEN OFF THE BUS (Xid 79 wedge). Flag set: $FLAG. NO auto-recovery — OS reboot required (human)."
  fault="$(gpu_bus_fault_dmesg)"; [ -n "$fault" ] && { echo "  kernel:"; echo "$fault" | sed 's/^/    /'; }
  exit 3
fi

# Case 2: not present at all (detached / powered off) OR driver can't answer. This
# is degraded for agent purposes (no local inference), but it is NOT necessarily a
# wedge — could be a deliberate safe-shutdown. Flag it so leafs go to Compass.
if ! gpu_present; then
  set_flag "gpu-absent"
  warn "no NVIDIA GPU on the bus (detached/powered off). Flag set: $FLAG."
  exit 2
fi
if ! gpu_responsive; then
  set_flag "driver-unresponsive"
  warn "nvidia-smi did not answer (driver unresponsive). Flag set: $FLAG."
  exit 2
fi

# Case 3 (H1): device is healthy, but is llama-swap actually using it? CPU-fallback
# reads healthy on every device check above, so it MUST be tested here. This is the
# serving-health check that closes the S3 gap.
if gpu_cpu_fallback; then
  vram="$(gpu_vram_used_mib || echo '?')"
  set_flag "cpu-fallback"
  warn "CPU-FALLBACK: a model is 'ready' but the GPU isn't serving it (VRAM=${vram} MiB, no/low llama-server residency). Flag set reason=cpu-fallback; leafs go DEGRADED."
  if remediate_cpu_fallback; then
    clear_flag; rm -f "$REMEDIATE_STAMP" 2>/dev/null || true
    ok "cpu-fallback remediated (serving resident); cleared flag."
    exit 0
  fi
  exit 2
fi

# Healthy and responsive. Auto-clear ONLY a soft flag; a wedge flag persists until
# a human clears it post-reboot (its reason won't be seen here because a wedge makes
# the checks above fail — but guard anyway in case of a stale wedge flag on a now-healthy card).
if [ -e "$FLAG" ]; then
  reason="$(flag_reason)"
  if [ "$reason" = "xid79-off-bus-wedge" ]; then
    warn "GPU now responds but a wedge flag persists (reason=$reason). Leaving it for a human to --clear after confirming a clean reboot."
    emit_metric 1 "$reason"
    exit 0
  fi
  clear_flag
  rm -f "$REMEDIATE_STAMP" 2>/dev/null || true   # episode over; next cpu-fallback gets its one attempt
  ok "GPU healthy; cleared prior soft degraded flag (was: $reason)."
  exit 0
fi

rm -f "$REMEDIATE_STAMP" 2>/dev/null || true       # fully healthy; no episode in progress
emit_metric 0
ok "GPU healthy and responsive."
exit 0
