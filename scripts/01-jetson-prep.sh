#!/usr/bin/env bash
# scripts/01-jetson-prep.sh
# Stage 1 – Jetson Environment Prep
#
# Actions:
#   0. Pre-flight: abort with the kernel's nvgpu errors if the iGPU is down
#   1. Install system dependencies
#   2. Remove any workspace agent config (.bob/) shipped to the device by rsync
#   3. Enable headless mode (disable gdm3/X11, free ~800MB–1GB unified RAM)
#   4. Check available memory from /proc/meminfo (warn below 6.0 GB)
#   5. Persistent 8 GB swapfile (idempotent; also done by ensure-swap.sh)
#   6. Set NVPModel power mode 2 (MAXN_SUPER) and verify it
#   7. Install persistent jetson-clocks.service
#
# The jetson-device-skills / agent skills are workspace-only (Mac) tooling and
# are deliberately NOT installed on the Jetson.
#
# Expects SUDO_PASS env var (set by setup-jetson.sh).
# State marker written by setup-jetson.sh: .setup-state/01_prep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── sudo helper ───────────────────────────────────────────────────────────────
# All privileged commands go through this so we never echo the password.
sudocmd() {
  echo "${SUDO_PASS}" | sudo -S "$@"
}

echo "── Stage 1: Jetson Environment Prep ─────────────────────────────────────"

# ── 0. GPU pre-flight ─────────────────────────────────────────────────────────
# Everything after this (jetson_clocks, the CUDA container) needs an initialised
# iGPU. If nvgpu failed to probe at boot, jetson_clocks dies with the opaque
# "GPU frequency scaling not supported" — fail early with the real cause instead.
echo "--> Checking the GPU is initialised..."
if ! nvidia-smi -L >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi sees no GPU — the iGPU did not initialise at boot."
  echo "       Kernel log (nvgpu errors this boot):"
  journalctl -k -b --no-pager 2>/dev/null | grep -E 'nvgpu.*\[ERR\]' | head -5 | sed 's/^/         /' || true
  echo "       Power-cycle or reboot the Jetson, then re-run Stage 1."
  exit 1
fi
echo "    GPU OK: $(nvidia-smi -L 2>/dev/null | head -1)"

# ── 1. System dependencies ────────────────────────────────────────────────────
echo "--> Installing system dependencies..."
sudocmd apt-get update -qq

# The serving path is a prebuilt llama.cpp container (Stage 3/4), so no CUDA
# toolkit or compiler toolchain is installed here.
# Docker + the NVIDIA container runtime ship with JetPack; Stage 3 verifies them.
sudocmd apt-get install -y \
  git curl wget jq \
  python3-pip python3-venv python3.12-venv \
  tpm2-tools

# Session 7-2e: vault/setup-tpm-auth.sh (run on the Mac) SSHes here and calls `tpm2_createek`; the
# stage must not pass without it. (On the current device tpm2-tools v5.6 was already present;
# availability of the apt package on a fresh image is inferred, not measured.)
command -v tpm2_createek >/dev/null 2>&1 \
  || { echo "ERROR: tpm2_createek not found after installing tpm2-tools (needed by 'make setup-tpm-auth' on the Mac)." >&2; exit 1; }
echo "    tpm2_createek: $(command -v tpm2_createek)"

# ── 2. Remove workspace agent config shipped by rsync ─────────────────────────
# The Mac workspace's .bob/ holds an MCP token and the agent skills. Current
# bootstrap-jetson.sh excludes it from rsync; this removes copies left by older
# syncs so the device never holds them.
if [[ -d "${REPO_ROOT}/.bob" ]]; then
  echo "--> Removing ${REPO_ROOT}/.bob (workspace agent config; not needed on device)..."
  rm -rf "${REPO_ROOT}/.bob"
fi

# ── 3. Headless mode (disable desktop GUI, free ~800MB–1GB RAM) ───────────────
echo "--> Enabling headless (multi-user) boot target..."
sudocmd systemctl set-default multi-user.target

# Stop active display managers gracefully; tolerate if not installed/running
for dm in gdm3 gdm lightdm; do
  if systemctl is-active --quiet "${dm}" 2>/dev/null; then
    echo "    Stopping ${dm}..."
    sudocmd systemctl stop "${dm}"
  fi
done

# Also disable them so they don't restart on a partial reboot
for dm in gdm3 gdm lightdm; do
  if systemctl is-enabled --quiet "${dm}" 2>/dev/null; then
    sudocmd systemctl disable "${dm}" 2>/dev/null || true
  fi
done

echo "    Headless mode set.  Desktop GUI can be restored with:"
echo "    sudo systemctl set-default graphical.target && sudo systemctl start gdm3"

# Give the kernel a moment to reclaim the display manager's pages
echo "    Waiting 5 s for memory to settle after display manager stop..."
sleep 5

# ── 4. Memory check ───────────────────────────────────────────────────────────
echo "--> Checking available memory..."

# /proc/meminfo MemAvailable is the authoritative measurement.
MEM_FREE_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)

MEM_FREE_GB=$(awk "BEGIN {printf \"%.2f\", ${MEM_FREE_KB}/1048576}")
echo "    Available unified memory: ${MEM_FREE_GB} GB (${MEM_FREE_KB} kB)"

# Threshold: 6.0 GB = 6291456 kB
# After gdm3 is killed, ~6.0–6.5 GB free is normal on an 8 GB Jetson
# (kernel, firmware, and background services consume ~1.5–2 GB).
# (Stale claim removed 2026-10-18: the vlm-server drop-in limits only the docker CLI cgroup.
#  The container's own swap limit is set and verified by scripts/04, see T-23.)
THRESHOLD_KB=6291456
if [[ "${MEM_FREE_KB}" -lt "${THRESHOLD_KB}" ]]; then
  echo "    WARNING: Free memory (${MEM_FREE_GB} GB) is below the 6.0 GB threshold."
  echo "    This may indicate residual memory consumers are active."
  echo "    Check with: sudo systemctl status gdm3"
  echo "    Continuing – but engine build may be tight on memory."
else
  echo "    Memory check PASSED (${MEM_FREE_GB} GB free, threshold 6.0 GB)."
fi

# ── 5. Persistent swapfile (8 GB, boot-activated via /etc/fstab) ─────────────
# Safety net for apt/pip/container-pull work on 8 GB unified RAM. Unlike zram
# (which compresses into unified RAM — counterproductive here), a disk-backed
# swapfile offloads pages to storage. At runtime the vlm-server container is
# started with --memory-swap == --memory AND re-asserted via systemctl set-property
# (Stage 4, ExecStartPost) because a daemon-reload resets the former (T-23, verified).
#
# Location: /swapfile (root filesystem — avoids writing into the repo tree)
SWAP_SIZE_GB=8
SWAP_FILE="/swapfile"

echo "--> Configuring persistent ${SWAP_SIZE_GB} GB swapfile at ${SWAP_FILE}..."

if swapon --show 2>/dev/null | grep -q "${SWAP_FILE}"; then
  echo "    Swapfile already active ($(swapon --show | grep "${SWAP_FILE}" | awk '{print $3}'))."
elif [[ -f "${SWAP_FILE}" ]]; then
  echo "    Swapfile exists but not active; enabling..."
  sudocmd swapon "${SWAP_FILE}"
else
  echo "    Creating ${SWAP_SIZE_GB} GB swap file (writes ~8 GB to disk)..."
  if sudocmd fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}" 2>/dev/null; then
    echo "    fallocate succeeded."
  else
    echo "    fallocate unavailable; falling back to dd (slow)..."
    sudocmd dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$(( SWAP_SIZE_GB * 1024 )) status=progress
  fi
  sudocmd chmod 600 "${SWAP_FILE}"
  sudocmd mkswap "${SWAP_FILE}"
  sudocmd swapon "${SWAP_FILE}"
  echo "    Swap active ($(swapon --show | grep "${SWAP_FILE}" | awk '{print $3}'))."
fi

# Persist via /etc/fstab so swap survives reboots during the multi-day build pipeline.
if ! grep -q "^${SWAP_FILE}" /etc/fstab 2>/dev/null; then
  echo "    Adding ${SWAP_FILE} to /etc/fstab for boot-time activation..."
  FSTAB_TMP="$(mktemp /tmp/fstab.XXXXXX)"
  cp /etc/fstab "${FSTAB_TMP}"
  echo "${SWAP_FILE} none swap sw 0 0" >> "${FSTAB_TMP}"
  sudocmd cp "${FSTAB_TMP}" /etc/fstab
  rm -f "${FSTAB_TMP}"
  echo "    /etc/fstab updated."
else
  echo "    /etc/fstab already contains ${SWAP_FILE}; skipping."
fi

SWAP_TOTAL_GB=$(awk '/SwapTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)
echo "    Total swap available: ${SWAP_TOTAL_GB} GB"

# ── 6. NVPModel power mode 2 (MAXN_SUPER) ────────────────────────────────────
# On JetPack 7 / kernel 6.8 nvpmodel prints "NVPM ERROR ... devfreq_dev/..." for
# GPU sysfs nodes that no longer exist, and `nvpmodel -m` can exit non-zero even
# though the mode is applied. So never trust the exit code: read the mode from
# stdout (stderr discarded) and verify it.
nvpmodel_name() { nvpmodel -q 2>/dev/null | awk '/NV Power Mode/ {print $NF}' || true; }

echo "--> Setting NVPModel power mode 2 (MAXN_SUPER)..."
if [[ "$(nvpmodel_name)" == "MAXN_SUPER" ]]; then
  echo "    Already in MAXN_SUPER."
else
  sudocmd nvpmodel -m 2 >/dev/null 2>&1 \
    || echo "    nvpmodel returned non-zero (known devfreq sysfs noise on JetPack 7) — verifying..."
  if [[ "$(nvpmodel_name)" != "MAXN_SUPER" ]]; then
    echo "ERROR: power mode is '$(nvpmodel_name)', expected MAXN_SUPER."
    exit 1
  fi
fi
echo "    Active power mode: $(nvpmodel_name)"

# ── 7. jetson-clocks persistent service ──────────────────────────────────────
echo "--> Installing jetson-clocks.service..."

# Write the unit to a temp file first, then copy with sudo.
# Using "sudo tee <<'HEREDOC'" is unreliable when sudo reads stdin via -S:
# the pipe can consume the heredoc, leaving tee with empty input.
CLOCKS_UNIT_TMP="$(mktemp /tmp/jetson-clocks-unit.XXXXXX)"
cat > "${CLOCKS_UNIT_TMP}" <<'UNIT'
[Unit]
Description=Jetson Max Clocks (MAXN_SUPER)
After=nvpmodel.service

[Service]
Type=oneshot
ExecStart=/usr/bin/jetson_clocks
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

sudocmd cp "${CLOCKS_UNIT_TMP}" /etc/systemd/system/jetson-clocks.service
sudocmd chmod 644 /etc/systemd/system/jetson-clocks.service
rm -f "${CLOCKS_UNIT_TMP}"

sudocmd systemctl daemon-reload
sudocmd systemctl enable jetson-clocks.service
sudocmd systemctl start  jetson-clocks.service

echo "    jetson-clocks.service enabled and started."

# ── complete ──────────────────────────────────────────────────────────────────
echo
echo "── Stage 1 complete ────────────────────────────────────────────────────"
