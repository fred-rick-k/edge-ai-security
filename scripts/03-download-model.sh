#!/usr/bin/env bash
# scripts/03-download-model.sh
# Stage 3 – Download Cosmos-Reason2-2B GGUF and pull the llama.cpp container.
#
# Model  : Kbenkhaled/Cosmos-Reason2-2B-GGUF (Q4_K_M quant, ~1.2 GB)
# Projector: mmproj-Cosmos-Reason2-2B-F16.gguf (~782 MB, vision encoder)
# Source : HuggingFace (public, no token required)
# Container: ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin
#
# State markers written:
#   03_download_model  – GGUF + projector downloaded to models/cosmos-reason2/
#   03_pull_container    – llama.cpp container image available locally
#
# No engine build needed — llama.cpp loads the GGUF directly at runtime.
# Expects SUDO_PASS env var.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.setup-state"
MODELS_DIR="${REPO_ROOT}/models/cosmos-reason2"

HF_REPO="Kbenkhaled/Cosmos-Reason2-2B-GGUF"
GGUF_FILE="Cosmos-Reason2-2B-Q4_K_M.gguf"
MMPROJ_FILE="mmproj-Cosmos-Reason2-2B-F16.gguf"
CONTAINER_IMAGE="ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin"

sudocmd() { echo "${SUDO_PASS}" | sudo -S "$@"; }
mark_done() { touch "${STATE_DIR}/$1"; echo "    Marker written: $1"; }
is_done()   { [[ -f "${STATE_DIR}/$1" ]]; }

mkdir -p "${STATE_DIR}" "${MODELS_DIR}"

echo "── Stage 3: Download Cosmos-Reason2-2B GGUF + pull container ───────────"

# ─────────────────────────────────────────────────────────────────────────────
# 3a. Download GGUF files
# ─────────────────────────────────────────────────────────────────────────────
# The files on disk are the source of truth, not the marker:
#   - marker present but a file is missing/empty -> clear the marker, re-download
#   - marker absent but both files present and plausibly sized -> write the marker
files_ok() {
  for f in "${GGUF_FILE}" "${MMPROJ_FILE}"; do
    [[ -s "${MODELS_DIR}/${f}" ]] || return 1
    [[ "$(du -sk "${MODELS_DIR}/${f}" | cut -f1)" -ge 102400 ]] || return 1
  done
}
if is_done "03_download_model" && ! files_ok; then
  echo "==> Marker 03_download_model present but model files missing — re-downloading."
  rm -f "${STATE_DIR}/03_download_model"
elif ! is_done "03_download_model" && files_ok; then
  echo "==> Model files already on disk — recording marker."
  mark_done "03_download_model"
fi

if is_done "03_download_model"; then
  echo "==> [SKIP] 03_download_model  (marker present)"
else
  echo "--> Downloading ${GGUF_FILE} (~1.2 GB) ..."
  curl -L --retry 5 --retry-delay 10 --progress-bar \
    "https://huggingface.co/${HF_REPO}/resolve/main/${GGUF_FILE}" \
    -o "${MODELS_DIR}/${GGUF_FILE}.tmp"
  mv "${MODELS_DIR}/${GGUF_FILE}.tmp" "${MODELS_DIR}/${GGUF_FILE}"
  echo "    ${GGUF_FILE}: $(du -sh "${MODELS_DIR}/${GGUF_FILE}" | cut -f1)"

  echo "--> Downloading ${MMPROJ_FILE} (~782 MB) ..."
  curl -L --retry 5 --retry-delay 10 --progress-bar \
    "https://huggingface.co/${HF_REPO}/resolve/main/${MMPROJ_FILE}" \
    -o "${MODELS_DIR}/${MMPROJ_FILE}.tmp"
  mv "${MODELS_DIR}/${MMPROJ_FILE}.tmp" "${MODELS_DIR}/${MMPROJ_FILE}"
  echo "    ${MMPROJ_FILE}: $(du -sh "${MODELS_DIR}/${MMPROJ_FILE}" | cut -f1)"

  # Quick sanity: both files must be > 100 MB
  for f in "${GGUF_FILE}" "${MMPROJ_FILE}"; do
    SIZE_KB=$(du -sk "${MODELS_DIR}/${f}" | cut -f1)
    if [[ "${SIZE_KB}" -lt 102400 ]]; then
      echo "ERROR: ${f} is suspiciously small (${SIZE_KB} kB) — download may have failed."
      rm -f "${MODELS_DIR}/${f}"
      exit 1
    fi
  done

  mark_done "03_download_model"
fi

echo "    GGUF : $(du -sh "${MODELS_DIR}/${GGUF_FILE}"  2>/dev/null | cut -f1)"
echo "    Proj : $(du -sh "${MODELS_DIR}/${MMPROJ_FILE}" 2>/dev/null | cut -f1)"

# ─────────────────────────────────────────────────────────────────────────────
# 3b. Pull the llama.cpp container image
# ─────────────────────────────────────────────────────────────────────────────
if is_done "03_pull_container"; then
  echo "==> [SKIP] 03_pull_container  (marker present)"
else
  echo "--> Pulling ${CONTAINER_IMAGE} ..."
  echo "    (first pull is ~2 GB; subsequent runs are instant)"
  sudocmd docker pull "${CONTAINER_IMAGE}"

  # Verify the image is present (docker image inspect: no pipe, no SIGPIPE risk)
  if ! sudocmd docker image inspect "${CONTAINER_IMAGE}" >/dev/null 2>&1; then
    echo "ERROR: Container pull succeeded but image not found in docker images."
    exit 1
  fi
  echo "    Container image pulled successfully."

  mark_done "03_pull_container"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3c. Configure NVIDIA runtime for Docker (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
# On JetPack 7 / Ubuntu 24.04 the NVIDIA container runtime is installed by
# nvidia-ctk but daemon.json may not have been updated.  A missing runtime entry
# causes "Unknown runtime specified nvidia" when Stage 4 starts the container.
echo "--> Ensuring Docker NVIDIA runtime is configured..."
DAEMON_JSON="/etc/docker/daemon.json"
NEEDS_RELOAD=false

if ! sudocmd test -s "${DAEMON_JSON}" 2>/dev/null; then
  # File is absent or empty — write a minimal config
  sudocmd bash -c "cat > '${DAEMON_JSON}' <<'EOF'
{
  \"default-runtime\": \"nvidia\",
  \"runtimes\": {
    \"nvidia\": {
      \"path\": \"nvidia-container-runtime\",
      \"runtimeArgs\": []
    }
  }
}
EOF"
  NEEDS_RELOAD=true
  echo "    Written ${DAEMON_JSON} (new)."
else
  # File exists — check for nvidia runtime entry
  if ! sudocmd grep -q '"nvidia"' "${DAEMON_JSON}" 2>/dev/null; then
    echo "WARNING: ${DAEMON_JSON} exists but has no nvidia runtime entry."
    echo "         Run: sudo nvidia-ctk runtime configure --runtime=docker"
    echo "         Then: sudo systemctl restart docker"
    echo "         Re-run Stage 3 afterwards."
    # Non-fatal: continue and let Stage 4 fail with a clearer message if needed.
  else
    echo "    NVIDIA runtime already in ${DAEMON_JSON}."
  fi
fi

if [[ "${NEEDS_RELOAD}" == "true" ]]; then
  sudocmd systemctl restart docker
  echo "    Docker daemon restarted."
fi

echo
echo "── Stage 3 complete ────────────────────────────────────────────────────"
echo "    Model  : ${MODELS_DIR}/${GGUF_FILE}"
echo "    Projector: ${MODELS_DIR}/${MMPROJ_FILE}"
echo "    Container: ${CONTAINER_IMAGE}"
