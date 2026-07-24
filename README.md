# gpu_rtx_3090 — RTX 3090 eGPU safety collaterals

Scripts to safely power-cycle the **NVIDIA RTX 3090** in its Thunderbolt-4 eGPU
enclosure (AOOSTAR AG02) without risking a wedged PCIe link, a hung `nvidia-smi`,
or corrupted in-flight work.

> Folder is named `gpu_rtx_3090` for the physical card, an RTX **3090**.

## Why this exists

The 3090 is an *external* GPU on a Thunderbolt tunnel. If the enclosure loses
power (or the cable is pulled) **while the driver is mid-DMA**, the PCIe link can
hang — symptoms: `nvidia-smi` freezes, containers stuck in `D` state, often a
host reboot to recover. These scripts **drain the GPU first**, and optionally
**hot-detach it from the OS**, so power-off is always clean.

PCI topology on this host (discovered dynamically, not hard-coded):
`0000:05:00.0` (VGA) + `0000:05:00.1` (HDMI audio), behind Thunderbolt.

## Scripts

| script | what it does |
|---|---|
| `gpu-status.sh` | Read-only health: util, VRAM, temp, power, fan, clocks, **PCIe link width** (TB-tunnel health), per-process VRAM. |
| `gpu-safe-shutdown.sh` | Stop GPU containers (`llama-swap`/`llama-arc`/`bench-llama`), wait for the card to go idle, force-kill stragglers. **Safe to power off after.** |
| `gpu-safe-shutdown.sh --detach` | …then PCIe hot-remove the device (`.1` then `.0`) after disabling persistence — a fully clean detach so you can hot power-off / unplug. |
| `gpu-power-up.sh [--serve]` | PCIe `rescan`, wait for re-enumeration, restore persistence; `--serve` also `docker start llama-swap`. Run after powering the enclosure back on. |
| `lib.sh` | Shared helpers (dynamic PCI discovery by vendor `0x10de`, `wait_for_gpu_idle`, container stop). |
| `gpu-safe-shutdown.service` | systemd unit that **drains** the GPU automatically on host shutdown/reboot. |
| `gpu-watchdog.sh` | Roadmap 12.1 health poll (systemd timer, ~30s). Flags `/run/agentops/gpu-degraded` + emits `agentops_gpu_degraded` metric on GPU wedge/absent/unresponsive **and** on silent CPU-fallback. Observe-and-flag; bounded opt-in remediation for cpu-fallback only. |

## `gpu-watchdog.sh` — the agent-fleet degraded signal (roadmap 12.1)

A cheap one-shot poll (systemd `gpu-watchdog.timer`, every ~30s during agent runs) that
sets `/run/agentops/gpu-degraded` (with a `reason=` line) and emits the Prometheus
`agentops_gpu_degraded{reason="…"}` textfile metric. The agent fleet reads the flag and
swaps leaf workers to Compass (**DEGRADED mode**); the metric drives the `AgentOpsGPUDegraded`
critical alert.

Two failure families are covered:

- **Device health (S3):** GPU wedged (Xid-79 off-bus), absent, or driver-unresponsive.
  `reason=xid79-off-bus-wedge` / `gpu-absent` / `driver-unresponsive`. **No auto-recovery** —
  a wedge needs an OS reboot (human).
- **Serving health (H1):** the GPU reads perfectly healthy but llama-swap silently serves on
  **CPU** after a bus re-enumeration left the container's CUDA handles stale (35B MoE ~13 tok/s;
  see qmd `[[llama-swap-cpu-fallback-stale-cuda]]`). Device checks miss this. Predicate:
  a model is `ready` **AND** VRAM `< 2 GB` (or no `llama-server` compute-app) ⇒
  `reason=cpu-fallback`.

```bash
gpu-watchdog.sh                    # poll once: set/clear flag + emit metric
gpu-watchdog.sh --status           # print flag state, touch nothing
gpu-watchdog.sh --simulate         # force a generic degraded flag (test; no GPU touch)
gpu-watchdog.sh --simulate-cpu-fallback   # force a cpu-fallback flag (test; no GPU touch)
gpu-watchdog.sh --clear            # clear a soft flag after verified recovery
```

**CPU-fallback remediation is OPT-IN and bounded.** Unlike a wedge, the fix is reversible —
one `docker compose -f /root/llama-swap/docker-compose.yml up -d --force-recreate` re-injects
the nvidia device → fresh CUDA handles (a child respawn does **not** fix it). Because the
serving is shared, the watchdog only performs it when a human opts in, and never more than
once per episode:

```bash
AGENTOPS_CPU_FALLBACK_REMEDIATE=1 gpu-watchdog.sh    # attempt the one-shot recreate, then verify residency
AGENTOPS_REMEDIATE_DRY_RUN=1 AGENTOPS_CPU_FALLBACK_REMEDIATE=1 gpu-watchdog.sh   # print the command, don't run it
```

Default (`REMEDIATE=0`) is flag + alert only, escalate to a human. If a single recreate does
not restore residency within ~60 s it escalates rather than loop-recreating (that could mask
the eGPU endurance fault). The **fleet-regression smoke** (`/root/llama-swap/fleet-regression.sh`,
step 4) also asserts GPU-residency so a CPU-fallback regression is caught by the harness, not
by a hung agent.

## `bebop` — Claude Code on the shim (single-model + the agent tree)

`bebop.sh` (sourced by `~/.bashrc`) wraps `claude` against the `cc-compass-shim`
(127.0.0.1:8088). The first arg picks a backend; the rest passes through to `claude`.

**Single-model entrypoints** (one model for the whole session):

| command | backend |
|---|---|
| `bebop` / `bebop compass` | Compass STAGE, `claude-opus-4.8` (default) |
| `bebop qwen` / `bebop qwen-big`\|`qwen35` / `bebop coder` / `bebop auto` | local models via llama-swap (one in VRAM at a time) |
| append `-think` | reasoning variant (e.g. `bebop qwen-big-think`) |

**bebop v3 — the frontier-fading agent TREE** (roadmap 12.1; opus plans, qwen executes,
telemetry earns the trust). The agent pack (roles, contracts, escalation, config) lives in
`$AGENTPACK_HOME` (default `/root/agent-pack`); `agentops` resolves each role's model for
the current **LOCAL/DEGRADED** mode at launch and injects the whole pack via `claude
--agents` — so the tree loads WITHOUT writing into your repo, and the role `.md` files stay
the single source of truth.

| command | what it launches |
|---|---|
| `bebop team [args…]` | orchestrator on `claude-opus-4.8` + the agent pack loaded. Plan-first (use shift-tab plan mode; the approved plan becomes the task contract). Local workers (executor/investigator/librarian/scribe) run on `qwen3.6-35b-a3b`; frontier specialists (judge/architect/rescuer) on Compass. |
| `bebop team-local [args…]` | the **destination** config: same tree, but the orchestrator itself is `qwen3.6-35b-a3b` (thinking on). Available from day 1 so its success rate is measured, not guessed — failure is an acceptable baseline. |
| `bebop ask <role> "question"` | direct **read-only** line to a leaf, no orchestrator hop (spike S1b). Roles: `investigator` (fleet/AIOps — "why is X firing", "what's eating VRAM") and `librarian` (recall/docs — "what do we know about Y"). Hard read-only: plan permission mode (harness-enforced) + the role's read-only tool allowlist — `ask` can never mutate. Write-shaped roles are refused with a pointer to `bebop team`. |

Notes:
- **Frontier is via the shim by default** (constraint #6). Every frontier call
  (orchestrator, judge, architect, rescuer, DEGRADED leafs) goes through the shim to
  Compass. The only exception is deliberately launching plain `claude` (Fable 5, Anthropic
  direct — no shim).
- **DEGRADED mode** (GPU down: the `/run/agentops/gpu-degraded` flag exists or llama-swap is
  unreachable at launch): the same tree runs, leafs swap to frontier by role affinity —
  opus-4.8 for executor/investigator, gpt-5.5 for librarian/scribe. `bebop team` prints a
  `MODE=DEGRADED` banner. Events are tagged `degraded=1`.
- **No-shim caveat:** plain `claude` (no shim) can load the pack but reaches neither
  llama-swap nor gpt-5.5 — it runs an all-Anthropic tree. Mixed *local* trees REQUIRE the
  shim (`bebop team`).
- **Config over code:** worker model, escalation budgets, and policy dials live in
  `agent-pack/agentpack.conf` — tuning never edits an agent definition.
- **Local workers serialize** (`--parallel 1`): the orchestrator dispatches local workers
  one at a time and batches reads (spike S2). Parallel fan-out is frontier-only.

## Typical use

```bash
# check before doing anything
sudo ./gpu-status.sh

# you want to power the enclosure off for the night:
sudo ./gpu-safe-shutdown.sh --detach      # drains, then removes from the OS
#   -> "SAFE to power off"; flip the enclosure switch

# next morning, after switching the enclosure on:
sudo ./gpu-power-up.sh --serve            # rescans the bus + restarts serving
```

Just stopping workloads (no physical power-off), e.g. to free VRAM:
```bash
sudo ./gpu-safe-shutdown.sh               # drain only
```

## Install the shutdown guard (recommended)

```bash
sudo cp gpu-safe-shutdown.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-safe-shutdown.service
```
On every reboot/poweroff the GPU is drained first (drain-only — it does **not**
auto-detach, to avoid surprising PCIe removals during normal reboots).

## Recovery cheatsheet

- `nvidia-smi` hangs / card gone after an unclean unplug → power the enclosure
  off, wait 5 s, on; then `sudo ./gpu-power-up.sh`.
- `gpu-status.sh` says "no NVIDIA GPU on the bus" → you detached it; power on +
  `gpu-power-up.sh`.
- PCIe link width `< x4` → Thunderbolt tunnel degraded (reseat the USB4 cable);
  this is the eGPU's known flaky failure mode and is alerted in the observability
  stack too.
- **GPU "fallen off the bus" (Xid 79) — the wedge.** `gpu-status.sh` shows the card
  ENUMERATED but UNRESPONSIVE: `nvidia-smi` prints "No devices were found", the PCIe
  width is blank, and a `thunderbolt` kworker is stuck in uninterruptible (D) sleep.
  **Only an OS reboot recovers this** — the driver's Xid 154 recovery action is
  literally "OS Reboot". Do **not** `--detach` / PCIe-rescan / TB-reauthorize: each
  queues onto the wedged TB kworker and hangs in D-state (unkillable), and you still
  end up rebooting. All three scripts now detect the wedge and exit 3 instead of
  hanging. Correct path:
  ```
  sudo ./gpu-power-up.sh --clear-wedge   # safe: kills stray nvidia-smi pollers, diagnoses
  sudo reboot                            # fleet.service restarts llama-swap on boot
  ```
  Reliably triggered by sustained heavy load (e.g. the coder `code_hard` benchmark) —
  a physical eGPU/TB4 endurance fault, not VRAM.

> Requires root (PCIe remove/rescan + persistence control). All scripts are
> idempotent and no-op cleanly if the card is already absent/idle.
