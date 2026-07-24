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
# It does NOT attempt recovery. A wedge needs an OS reboot (detach/rescan queues
# onto the stuck thunderbolt kworker and hangs — see gpu-status.sh / lib.sh).
# That is a human call; the watchdog only observes, flags, and alerts.
#
# The orchestrator's dispatch prompt reads /run/agentops/gpu-degraded: present =>
# route leaf work to Compass (DEGRADED mode) and say so.
#
# Run once (systemd timer, every ~30s during agent runs) or by hand:
#   gpu-watchdog.sh            # poll once, set/clear flag, emit metric
#   gpu-watchdog.sh --simulate # force a degraded flag+metric for testing (no GPU touch)
#   gpu-watchdog.sh --clear    # clear a flag (e.g. after a verified reboot recovery)
#   gpu-watchdog.sh --status   # print current flag state, touch nothing
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

FLAG_DIR="${AGENTOPS_RUN_DIR:-/run/agentops}"
FLAG="$FLAG_DIR/gpu-degraded"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
METRIC="$TEXTFILE_DIR/agentops_gpu.prom"

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
esac

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
  ok "GPU healthy; cleared prior soft degraded flag (was: $reason)."
  exit 0
fi

emit_metric 0
ok "GPU healthy and responsive."
exit 0
