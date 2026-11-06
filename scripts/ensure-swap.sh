#!/usr/bin/env bash
# scripts/ensure-swap.sh
# Ensure a persistent 8 GB swapfile exists at /swapfile and is active.
#
# This script is ALWAYS run by bootstrap-jetson.sh before any stage, outside
# the state-marker system.  It is fully idempotent: running it multiple times
# is safe.
#
# Design rationale:
#   - A disk-backed swapfile is a safety net for on-device installs and builds
#     on 8 GB unified RAM (apt, pip, container pulls).
#   - zram is NOT used: it compresses pages back into unified RAM.
#   - At runtime the inference container is started with --memory-swap equal to
#     --memory (Stage 4), so it never uses swap during live inference.
#
# Expects SUDO_PASS env var (set by setup-jetson.sh / bootstrap-jetson.sh).

set -euo pipefail

SWAP_FILE="/swapfile"
SWAP_SIZE_GB=8

sudocmd() {
  echo "${SUDO_PASS}" | sudo -S "$@"
}

echo "── Swap: ensuring ${SWAP_SIZE_GB} GB persistent swapfile ────────────────"

# ── already active? ───────────────────────────────────────────────────────────
if swapon --show 2>/dev/null | grep -q "^${SWAP_FILE}"; then
  ACTIVE_SIZE=$(swapon --show | awk -v f="${SWAP_FILE}" '$1==f {print $3}')
  echo "    Already active: ${SWAP_FILE} (${ACTIVE_SIZE}). Nothing to do."
  exit 0
fi

# ── file exists but not active? ───────────────────────────────────────────────
if [[ -f "${SWAP_FILE}" ]]; then
  echo "    Swapfile exists but not active — enabling..."
  sudocmd swapon "${SWAP_FILE}"
  echo "    Swap enabled: $(swapon --show | awk -v f="${SWAP_FILE}" '$1==f {print $3}')"
else
  # ── create swapfile ───────────────────────────────────────────────────────
  echo "    Creating ${SWAP_SIZE_GB} GB swapfile at ${SWAP_FILE}..."
  # fallocate is instant on ext4/xfs; falls back to dd on filesystems that
  # don't support it (e.g. btrfs, certain tmpfs configs)
  if sudocmd fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}" 2>/dev/null; then
    echo "    fallocate: done."
  else
    echo "    fallocate unavailable; using dd (slow — ~60 s)..."
    sudocmd dd if=/dev/zero of="${SWAP_FILE}" bs=1M \
      count=$(( SWAP_SIZE_GB * 1024 )) status=progress
  fi
  sudocmd chmod 600 "${SWAP_FILE}"
  sudocmd mkswap "${SWAP_FILE}"
  sudocmd swapon "${SWAP_FILE}"
  echo "    Swap created and enabled: $(swapon --show | awk -v f="${SWAP_FILE}" '$1==f {print $3}')"
fi

# ── persist via /etc/fstab ────────────────────────────────────────────────────
if ! grep -q "^${SWAP_FILE}" /etc/fstab 2>/dev/null; then
  echo "    Adding ${SWAP_FILE} to /etc/fstab..."
  FSTAB_TMP="$(mktemp /tmp/fstab.XXXXXX)"
  cp /etc/fstab "${FSTAB_TMP}"
  echo "${SWAP_FILE} none swap sw 0 0" >> "${FSTAB_TMP}"
  sudocmd cp "${FSTAB_TMP}" /etc/fstab
  rm -f "${FSTAB_TMP}"
  echo "    /etc/fstab updated."
else
  echo "    /etc/fstab already contains ${SWAP_FILE}."
fi

echo "    SwapTotal: $(awk '/SwapTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo)"
echo "── Swap: ready ─────────────────────────────────────────────────────────"
