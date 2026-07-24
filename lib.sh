#!/usr/bin/env bash
# Shared helpers for the RTX 3090 eGPU safety scripts.
# Sourced by gpu-status.sh / gpu-safe-shutdown.sh / gpu-power-up.sh.
#
# The card is an NVIDIA RTX 3090 (vendor 0x10de) in a Thunderbolt 4 eGPU
# enclosure. On this host it enumerates at PCI 0000:05:00.0 (VGA) + 0000:05:00.1
# (HDMI audio), but we DISCOVER the address dynamically so a re-plug at a
# different slot still works.
set -uo pipefail
export LC_ALL=C LANG=C

# Containers known to hold the GPU (current + legacy + benchmark harness).
GPU_CONTAINERS=(llama-swap llama-arc bench-llama)

log()  { printf '\033[36m[gpu]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[err]\033[0m %s\n' "$*" >&2; }

# All NVIDIA PCI functions, VGA/3D first and audio (.1+) last — but for REMOVAL
# we want the highest function first, so callers reverse as needed.
gpu_pci_funcs() {
  local d vendor
  for d in /sys/bus/pci/devices/*/; do
    vendor="$(cat "$d/vendor" 2>/dev/null || true)"
    [ "$vendor" = "0x10de" ] && basename "$d"
  done | sort
}

# The bus the GPU sits on (e.g. 0000:05) — used to confirm a clean detach.
gpu_bus() { gpu_pci_funcs | head -1 | cut -d: -f1,2; }

# PIDs with a compute context on the GPU (empty => idle).
gpu_compute_pids() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null \
    | tr -d ' ' | grep -E '^[0-9]+$' || true
}

gpu_present() {
  # present if any NVIDIA function exists on the PCI bus
  [ -n "$(gpu_pci_funcs)" ]
}

# Is the driver able to actually talk to the card? (present on the bus but
# unresponsive => "fallen off the bus" wedge.)
# NOTE: `nvidia-smi -L` exits 0 even when it prints "No devices found." on a
# dead card, so we must match an actual "GPU N:" line, not the exit code.
gpu_responsive() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  timeout 8 nvidia-smi -L 2>/dev/null | grep -qE '^GPU [0-9]+:'
}

# Detect the Xid 79 "GPU has fallen off the bus" wedge. In this state the PCI
# function stays ENUMERATED (so gpu_present is true) but the GPU is dead:
# nvidia-smi returns "No devices were found", pcie.link.width reads blank, and a
# thunderbolt kworker is typically stuck in uninterruptible (D) sleep. The
# driver's own Xid 154 recovery action is "OS Reboot". detach+rescan does NOT
# recover this — the PCIe remove/rescan queues onto the already-wedged
# thunderbolt kworker and hangs the same way. ONLY an OS reboot clears it.
# Returns 0 (true) when the wedge is detected.
gpu_off_bus_wedge() {
  gpu_present || return 1        # nothing on the bus => detached/off, not wedged
  gpu_responsive && return 1     # driver can talk to it => healthy, not wedged
  return 0
}

# --- H1: CPU-fallback / stale-CUDA serving-health helpers (roadmap 12.1 v4) ----
# The device can read perfectly healthy (gpu_present + gpu_responsive true) while
# llama-swap silently serves on CPU after a bus re-enumeration left the container's
# CUDA handles stale (see qmd [[llama-swap-cpu-fallback-stale-cuda]]). gpu_off_bus_wedge
# and friends CANNOT see this — it is a SERVING-health check, not a DEVICE-health check.
#
# Every input here is env-overridable so the predicate can be unit-tested against a
# SYNTHESIZED (/running ready + low VRAM) state with no GPU and no live serving:
#   VRAM_USED_OVERRIDE   — MiB integer, bypasses nvidia-smi
#   COMPUTE_APPS_OVERRIDE— newline/space list of process names, bypasses nvidia-smi
#   LLAMA_SWAP_RUNNING_OVERRIDE — raw JSON string, bypasses the curl to /running
LLAMA_SWAP_URL="${LLAMA_SWAP_URL:-http://127.0.0.1:8081}"
CPU_FALLBACK_VRAM_MIB="${CPU_FALLBACK_VRAM_MIB:-2048}"   # < this while a model is 'ready' => CPU-fallback

# Total VRAM used, MiB (integer). Prints nothing + returns 1 if it can't be read.
# Overrides use is-SET (${VAR+x}) not is-non-empty, so an explicit empty injected
# value is honoured (e.g. COMPUTE_APPS_OVERRIDE="" means "no compute apps").
gpu_vram_used_mib() {
  if [ -n "${VRAM_USED_OVERRIDE+x}" ]; then printf '%s\n' "$VRAM_USED_OVERRIDE"; return 0; fi
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  local v
  v="$(timeout 8 nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
  [ -n "$v" ] && printf '%s\n' "$v" || return 1
}

# True (0) if a `llama-server` compute app currently holds the GPU.
gpu_has_llama_compute_app() {
  local apps
  if [ -n "${COMPUTE_APPS_OVERRIDE+x}" ]; then apps="$COMPUTE_APPS_OVERRIDE";
  else
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    apps="$(timeout 8 nvidia-smi --query-compute-apps=process_name --format=csv,noheader 2>/dev/null)"
  fi
  printf '%s' "$apps" | grep -q 'llama-server'
}

# Raw llama-swap /running JSON (best effort). Empty on failure.
llama_swap_running_json() {
  if [ -n "${LLAMA_SWAP_RUNNING_OVERRIDE+x}" ]; then printf '%s' "$LLAMA_SWAP_RUNNING_OVERRIDE"; return 0; fi
  command -v curl >/dev/null 2>&1 || return 0
  curl -s --max-time 6 "$LLAMA_SWAP_URL/running" 2>/dev/null || true
}

# True (0) if llama-swap reports at least one model in state "ready".
llama_swap_model_ready() {
  llama_swap_running_json | grep -q '"state" *: *"ready"'
}

# THE H1 PREDICATE. True (0) == CPU-fallback: a model is loaded/ready but the GPU
# is not actually doing the work. Deliberately conservative — it only fires when a
# model claims 'ready' (so an idle, swapped-out model with low VRAM is NOT flagged).
# CPU-fallback == ready AND (VRAM below the floor OR no llama-server compute app).
gpu_cpu_fallback() {
  llama_swap_model_ready || return 1            # no model ready => not this failure
  local vram
  if vram="$(gpu_vram_used_mib)" && [ -n "$vram" ]; then
    [ "$vram" -lt "$CPU_FALLBACK_VRAM_MIB" ] && return 0
  fi
  gpu_has_llama_compute_app || return 0         # ready but no compute app => CPU-fallback
  return 1
}

# Recent "fallen off the bus" / Xid 79 / Xid 154 evidence in the kernel ring
# buffer (best-effort; needs readable dmesg). Prints matching lines.
gpu_bus_fault_dmesg() {
  dmesg -T 2>/dev/null | grep -iE "fallen off the bus|Xid.*: (79|154)|recovery action" | tail -6 || true
}

# Thunderbolt worker threads stuck in uninterruptible (D) sleep — the signature
# that a PCIe remove/rescan will hang rather than recover.
gpu_tb_dstate_workers() {
  ps -eo stat,comm 2>/dev/null | awk '$1 ~ /^D/ && $2 ~ /thunderbolt/ {print $2}' || true
}

# Kill stray `nvidia-smi -l/--loop` pollers that keep an fd open on /dev/nvidia*
# against a dead card (they block a clean module unload and spin uselessly).
kill_stray_smi_pollers() {
  local pids
  pids="$(pgrep -f 'nvidia-smi.*(-l|--loop)' 2>/dev/null || true)"
  [ -z "$pids" ] && return 0
  log "killing stray nvidia-smi pollers: $pids"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 1
}

# Block until no compute apps remain, or timeout (seconds). Returns 0 if idle.
wait_for_gpu_idle() {
  local timeout="${1:-120}" t0 now
  t0=$(date +%s)
  while :; do
    [ -z "$(gpu_compute_pids)" ] && return 0
    now=$(date +%s)
    if [ $((now - t0)) -ge "$timeout" ]; then return 1; fi
    sleep 2
  done
}

# Stop any GPU-holding containers that are currently running.
stop_gpu_containers() {
  command -v docker >/dev/null 2>&1 || { warn "docker not found; skipping containers"; return 0; }
  local c running
  for c in "${GPU_CONTAINERS[@]}"; do
    running="$(docker ps -q -f "name=^${c}$" 2>/dev/null)"
    if [ -n "$running" ]; then
      log "stopping container: $c"
      docker stop -t 25 "$c" >/dev/null 2>&1 || warn "could not stop $c"
    fi
  done
}
