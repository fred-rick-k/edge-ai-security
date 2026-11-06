#!/usr/bin/env bash
# scripts/cleanup-jetson.sh
# Revert changes made by the setup scripts on the Jetson.
#
# Run this when something breaks and you want a clean slate, or to fully
# uninstall components from the device.
#
# What it undoes:
#   Phase 2 (Stage 2-1 / webui):
#              stops/disables/removes live-vlm-webui.service, removes ui/.venv & tls/
#   Phase 1 (Stage 1-3 / vlm):
#              stops/disables/removes vlm-server.service + drop-in + container
#              removes /etc/sudoers.d/vlm-dropcaches
#   Phase 1 (Stage 1-2 / model):
#              removes models/ (GGUF + mmproj); markers 03_*
#   Phase 1 (Stage 1-1 / prep):
#              re-enables graphical.target (desktop GUI), removes jetson-clocks.service,
#              resets nvpmodel to SKU default, removes /swapfile
#   All:       removes .setup-state/ markers and ~/edge-device-demo itself
#              (optional, guarded by --full flag)
#
# Usage (run ON the Jetson, or via bootstrap-jetson.sh --cleanup from Mac):
#   ~/edge-device-demo/scripts/cleanup-jetson.sh               # revert all stages
#   ~/edge-device-demo/scripts/cleanup-jetson.sh --phase 2     # revert Phase 2 only
#   ~/edge-device-demo/scripts/cleanup-jetson.sh --stage webui # revert specific stage
#   ~/edge-device-demo/scripts/cleanup-jetson.sh --full        # also delete repo
#
# Expects SUDO_PASS env var, OR prompts interactively.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.setup-state"

# ── parse args ────────────────────────────────────────────────────────────────
FULL_WIPE=false
STAGE_FILTER=""
PHASE_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)     FULL_WIPE=true; shift ;;
    --phase)    PHASE_FILTER="$2"; shift 2 ;;
    --phase=*)  PHASE_FILTER="${1#--phase=}"; shift ;;
    --stage)    STAGE_FILTER="$2"; shift 2 ;;
    --stage=*)  STAGE_FILTER="${1#--stage=}"; shift ;;
    --help|-h)
      sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── sudo helper ───────────────────────────────────────────────────────────────
if [[ -z "${SUDO_PASS:-}" ]]; then
  read -rsp "Jetson sudo password: " SUDO_PASS
  echo
  export SUDO_PASS
fi

# Validate immediately
echo "${SUDO_PASS}" | sudo -S true 2>/dev/null \
  || { echo "ERROR: sudo password invalid."; exit 1; }

sudocmd() {
  echo "${SUDO_PASS}" | sudo -S "$@"
}

# ── helper: should we run this stage/phase? ───────────────────────────────────
should_run_stage() {
  local stage_name="$1"
  local phase_num="$2"

  if [[ -n "${PHASE_FILTER}" ]]; then
    [[ "${PHASE_FILTER}" == "${phase_num}" ]] && return 0 || return 1
  fi

  if [[ -n "${STAGE_FILTER}" ]]; then
    case "${STAGE_FILTER}" in
      "${stage_name}"|"${phase_num}-${stage_name}") return 0 ;;
      *) return 1 ;;
    esac
  fi

  return 0
}

remove_systemd_service() {
  local svc="$1"
  local svc_file="/etc/systemd/system/${svc}.service"
  local dropin_dir="/etc/systemd/system/${svc}.service.d"

  if systemctl is-active --quiet "${svc}" 2>/dev/null; then
    echo "--> Stopping ${svc}.service..."
    sudocmd systemctl stop "${svc}.service"
  fi
  if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
    echo "--> Disabling ${svc}.service..."
    sudocmd systemctl disable "${svc}.service"
  fi
  if [[ -f "${svc_file}" ]]; then
    echo "--> Removing ${svc_file}..."
    sudocmd rm -f "${svc_file}"
  fi
  if [[ -d "${dropin_dir}" ]]; then
    echo "--> Removing drop-in ${dropin_dir}..."
    sudocmd rm -rf "${dropin_dir}"
  fi
  if command -v docker >/dev/null 2>&1; then
    sudocmd docker rm -f "${svc}" 2>/dev/null || true
  fi
}

echo "════════════════════════════════════════════════════"
echo "  Jetson System Cleanup"
echo "  Repo root : ${REPO_ROOT}"
echo "  Full wipe : ${FULL_WIPE}"
[[ -n "${PHASE_FILTER}" ]] && echo "  Phase only: ${PHASE_FILTER}"
[[ -n "${STAGE_FILTER}" ]] && echo "  Stage only: ${STAGE_FILTER}"
echo "════════════════════════════════════════════════════"
echo

# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 Stage 3-5j cleanup – camera credential template + LoadCredential drop-ins
# (the WebUI then has NO camera source until the stage is re-run; camera.env is not recreated)
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "camera-credential" "3" || should_run_stage "3-5j" "3" || should_run_stage "14_camera_credential" "3"; then
  echo "── Reverting Phase 3 Stage 3-5j (camera credential template) ─────────────"
  sudocmd rm -f /etc/systemd/system/live-vlm-webui.service.d/10-camera-credential.conf \
                /etc/systemd/system/vault-agent.service.d/20-webui-camera-dir.conf
  sudocmd rm -rf /run/webui-camera
  if sudocmd test -f /etc/vault-agent/vault-agent.hcl.pre-3-5j; then
    echo "--> Restoring /etc/vault-agent/vault-agent.hcl from .pre-3-5j (template block removed)..."
    sudocmd cp -p /etc/vault-agent/vault-agent.hcl.pre-3-5j /etc/vault-agent/vault-agent.hcl
    sudocmd rm -f /etc/vault-agent/vault-agent.hcl.pre-3-5j
  fi
  sudocmd systemctl daemon-reload
  sudocmd systemctl restart vault-agent 2>/dev/null || true
  rm -f "${STATE_DIR}/14_camera_credential"
  echo "    Phase 3 Stage 3-5j artifacts removed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 Stage 3-5i cleanup – persistent camera-agent sandbox
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "agent-sandbox" "3" || should_run_stage "3-5i" "3" || should_run_stage "13b_agent_sandbox" "3"; then
  echo "── Reverting Phase 3 Stage 3-5i (persistent camera-agent sandbox) ────────"
  if openshell sandbox list 2>/dev/null | grep -q "^camera-agent[[:space:]]"; then
    echo "--> Deleting sandbox camera-agent..."
    openshell sandbox delete camera-agent 2>/dev/null || true
  fi
  if docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -q "^edge-agent-sandbox:dev$"; then
    echo "--> Removing Docker image edge-agent-sandbox:dev..."
    sudocmd docker rmi edge-agent-sandbox:dev 2>/dev/null || true
  fi
  rm -f "${STATE_DIR}/13b_agent_sandbox"
  echo "    Phase 3 Stage 3-5i artifacts removed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 Stage 3-5h cleanup – permanent gateway Vault driver + providers
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "gateway-vault-driver" "3" || should_run_stage "3-5h" "3" || should_run_stage "13a_gateway_vault_driver" "3"; then
  echo "── Reverting Phase 3 Stage 3-5h (gateway Vault driver + providers) ────────"
  # Delete providers (this also removes their Vault KV entries via the driver)
  for prov in edge-ingest cosmos-vlm; do
    if openshell provider list 2>/dev/null | grep -q "^${prov} "; then
      echo "--> Deleting provider ${prov}..."
      openshell provider delete "${prov}" 2>/dev/null || true
    fi
  done
  # Delete profiles
  for prof in edge-ingest cosmos-vlm; do
    if openshell profile list 2>/dev/null | grep -q "^${prof} "; then
      echo "--> Deleting profile ${prof}..."
      openshell profile delete "${prof}" 2>/dev/null || true
    fi
  done
  # Restore gateway.toml from the backup (if one exists)
  GW_BACKUP="${HOME}/.config/openshell/gateway.toml.pre-3-5h"
  GW_TOML="${HOME}/.config/openshell/gateway.toml"
  if [[ -f "${GW_BACKUP}" ]]; then
    echo "--> Restoring ${GW_TOML} from backup ${GW_BACKUP}..."
    local_tmp="${GW_TOML}.cleanup.$$"
    cp "${GW_BACKUP}" "${local_tmp}" && chmod 644 "${local_tmp}" && mv -f "${local_tmp}" "${GW_TOML}" \
      && echo "--> Restored. Restarting openshell-gateway..." \
      && systemctl --user restart openshell-gateway 2>/dev/null \
      || echo "    WARNING: could not restore gateway.toml or restart gateway — check manually."
  else
    echo "--> No backup found at ${GW_BACKUP}; gateway.toml not restored."
  fi
  rm -f "${STATE_DIR}/13a_gateway_vault_driver"
  echo "    Phase 3 Stage 3-5h artifacts removed."
  echo "    NOTE: if the handoff file /etc/trusted-edge/ingest-key.handoff was already deleted,"
  echo "          the ingest key is only in Vault; to recreate it you must re-run stage 3-5g then 3-5h."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 Stage 3-5g cleanup – trusted-edge
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "trusted-edge" "3" || should_run_stage "3-5g" "3" || should_run_stage "13_trusted_edge" "3"; then
  echo "── Reverting Phase 3 Stage 3-5g (trusted-edge) ───────────────────────────"
  remove_systemd_service "trusted-edge"
  if [[ -f /etc/systemd/system/vault-agent.service.d/10-sinkdir-group.conf ]]; then
    echo "--> Removing vault-agent drop-in 10-sinkdir-group.conf..."
    sudocmd rm -f /etc/systemd/system/vault-agent.service.d/10-sinkdir-group.conf
    sudocmd rmdir /etc/systemd/system/vault-agent.service.d 2>/dev/null || true
  fi
  sudocmd systemctl daemon-reload
  for d in /opt/trusted-edge /etc/trusted-edge; do
    if [[ -d "${d}" ]]; then
      echo "--> Removing ${d}..."
      sudocmd rm -rf "${d}"
    fi
  done
  openshell sandbox delete te-src-probe >/dev/null 2>&1 || true
  rm -f "${STATE_DIR}/13_trusted_edge"
  echo "    Phase 3 Stage 3-5g artifacts removed."
  echo "    NOTE: the SHA-256 in Vault KV edge-device/ingest-key is create-only and stays; delete it"
  echo "          on the Mac (root) before re-running the stage after removing the handoff key:"
  echo "          vault kv metadata delete -mount=edge-ai-demo-kv edge-device/ingest-key"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5 Stage 5-2 cleanup – Agent pipeline
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "agent-pipeline" "5" || should_run_stage "5-2" "5" || should_run_stage "12_agent_pipeline" "5"; then
  echo "── Reverting Phase 5 Stage 5-2 (Agent Pipeline) ──────────────────────────"
  if [[ -d "${REPO_ROOT}/agent/.venv" ]]; then
    echo "--> Removing ${REPO_ROOT}/agent/.venv..."
    rm -rf "${REPO_ROOT}/agent/.venv"
  fi
  rm -f "${STATE_DIR}/12_agent_pipeline"
  echo "    Phase 5 Stage 5-2 artifacts removed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5 Stage 5-1b cleanup – Vault Agent Gateway instance
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "tpm-gateway-agent" "5" || should_run_stage "5-1b" "5" || should_run_stage "11b_tpm_gateway_agent" "5"; then
  echo "── Reverting Phase 5 Stage 5-1b (Vault Agent Gateway) ────────────────────"
  remove_systemd_service "vault-agent-gateway"
  sudocmd systemctl daemon-reload
  if [[ -f /etc/vault-agent/vault-agent-gateway.hcl ]]; then
    echo "--> Removing /etc/vault-agent/vault-agent-gateway.hcl..."
    sudocmd rm -f /etc/vault-agent/vault-agent-gateway.hcl
  fi
  if [[ -d /etc/vault-agent/tpm-gateway ]]; then
    echo "--> Removing /etc/vault-agent/tpm-gateway..."
    sudocmd rm -rf /etc/vault-agent/tpm-gateway
  fi
  if [[ -f /run/openshell/vault-token ]]; then
    echo "--> Removing /run/openshell/vault-token..."
    sudocmd rm -f /run/openshell/vault-token
  fi
  rm -f "${STATE_DIR}/11b_tpm_gateway_agent"
  echo "    Phase 5 Stage 5-1b artifacts removed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5 Stage 5-1 cleanup – Vault Agent Edge instance
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "tpm-agent" "5" || should_run_stage "5-1" "5" || should_run_stage "11_tpm_agent" "5" || should_run_stage "tpm" "5"; then
  echo "── Reverting Phase 5 Stage 5-1 (Vault Agent Edge) ───────────────────────"
  remove_systemd_service "vault-agent"
  sudocmd systemctl daemon-reload
  if [[ -f /etc/vault-agent/vault-agent.hcl ]]; then
    echo "--> Removing /etc/vault-agent/vault-agent.hcl..."
    sudocmd rm -f /etc/vault-agent/vault-agent.hcl
  fi
  if [[ -d /etc/vault-agent/tpm-edge ]]; then
    echo "--> Removing /etc/vault-agent/tpm-edge..."
    sudocmd rm -rf /etc/vault-agent/tpm-edge
  fi
  if [[ -d /etc/vault-agent/tpm ]]; then
    echo "--> Removing legacy /etc/vault-agent/tpm..."
    sudocmd rm -rf /etc/vault-agent/tpm
  fi
  if [[ -d /run/openshell-edge ]]; then
    echo "--> Removing /run/openshell-edge..."
    sudocmd rm -rf /run/openshell-edge
  fi
  rm -f "${STATE_DIR}/11_tpm_agent"
  echo "    Phase 5 Stage 5-1 artifacts removed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 Stage 1 (3-1) cleanup – OpenShell supervisor + policy
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "openshell" "3" || should_run_stage "3-1" "3" || should_run_stage "10_openshell" "3"; then
  echo "── Reverting Phase 3 (OpenShell Sandbox) ──────────────────────────────────"

  if systemctl is-active --quiet openshell-supervisor 2>/dev/null; then
    echo "--> Stopping openshell-supervisor.service..."
    sudocmd systemctl stop openshell-supervisor.service
  fi
  if systemctl is-enabled --quiet openshell-supervisor 2>/dev/null; then
    sudocmd systemctl disable openshell-supervisor.service 2>/dev/null || true
  fi
  if [[ -f /etc/systemd/system/openshell-supervisor.service ]]; then
    sudocmd rm -f /etc/systemd/system/openshell-supervisor.service
    sudocmd systemctl daemon-reload
  fi

  if [[ -d /etc/openshell ]]; then
    echo "--> Removing /etc/openshell (sandbox policies)..."
    sudocmd rm -rf /etc/openshell
  fi
  if [[ -d /var/log/openshell ]]; then
    echo "--> Removing /var/log/openshell (audit log)..."
    sudocmd rm -rf /var/log/openshell
  fi

  rm -f "${STATE_DIR}/10_openshell"
  echo "    Phase 3 OpenShell artifacts removed."
fi

# Phase 2 Stage 1 (2-1) cleanup – live-vlm-webui.service, venv, TLS
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "webui" "2" || should_run_stage "2-1" "2" || should_run_stage "09_webui" "2"; then
  echo "── Reverting Phase 2 (Live VLM WebUI) ──────────────────────────────────"

  remove_systemd_service "live-vlm-webui"
  sudocmd systemctl daemon-reload

  if [[ -d "${REPO_ROOT}/ui/.venv" ]]; then
    echo "--> Removing ${REPO_ROOT}/ui/.venv..."
    rm -rf "${REPO_ROOT}/ui/.venv"
  fi

  if [[ -d "${REPO_ROOT}/tls" ]]; then
    echo "--> Removing ${REPO_ROOT}/tls..."
    rm -rf "${REPO_ROOT}/tls"
  fi

  rm -f "${STATE_DIR}/09_webui"
  echo "    Phase 2 WebUI artifacts removed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 Stage 1-3 (4) cleanup – vlm-server.service
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "vlm" "1" || should_run_stage "1-3" "1" || should_run_stage "4" "1" || should_run_stage "08_services" "1"; then
  echo "── Reverting Phase 1 Stage 1-3: vlm-server service ────────────────────"

  remove_systemd_service "vlm-server"
  remove_systemd_service "cosmos3-shim"  # legacy cleanup

  sudocmd systemctl daemon-reload
  echo "    Services removed."

  for sudoers_file in /etc/sudoers.d/vlm-dropcaches /etc/sudoers.d/cosmos3-dropcaches; do
    if [[ -f "${sudoers_file}" ]]; then
      echo "--> Removing ${sudoers_file}..."
      sudocmd rm -f "${sudoers_file}"
    fi
  done

  rm -f "${STATE_DIR}/08_services"
  echo "    Phase 1 VLM service reverted."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 Stage 1-2 (3) cleanup – GGUF models + container image
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "model" "1" || should_run_stage "1-2" "1" || should_run_stage "3" "1" || should_run_stage "03_download_model" "1"; then
  echo "── Reverting Phase 1 Stage 1-2: models & container image ───────────────"

  if [[ -d "${REPO_ROOT}/models" ]]; then
    echo "--> Removing ${REPO_ROOT}/models..."
    rm -rf "${REPO_ROOT}/models"
  fi

  if command -v docker >/dev/null 2>&1; then
    sudocmd docker rmi ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin 2>/dev/null || true
  fi

  rm -f \
    "${STATE_DIR}/03_download_model" \
    "${STATE_DIR}/03_pull_container" \
    "${STATE_DIR}/03_download_cosmos3"
  echo "    Phase 1 model artifacts removed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 Stage 1-1 (1) cleanup – headless mode, clocks, swap
# ─────────────────────────────────────────────────────────────────────────────
if should_run_stage "prep" "1" || should_run_stage "1-1" "1" || should_run_stage "1" "1" || should_run_stage "01_prep" "1"; then
  echo "── Reverting Phase 1 Stage 1-1: environment prep ───────────────────────"

  if systemctl is-active --quiet "jetson-clocks" 2>/dev/null; then
    echo "--> Stopping jetson-clocks.service..."
    sudocmd systemctl stop jetson-clocks.service
  fi
  if systemctl is-enabled --quiet "jetson-clocks" 2>/dev/null; then
    sudocmd systemctl disable jetson-clocks.service 2>/dev/null || true
  fi
  if [[ -f /etc/systemd/system/jetson-clocks.service ]]; then
    echo "--> Removing jetson-clocks.service..."
    sudocmd rm -f /etc/systemd/system/jetson-clocks.service
    sudocmd systemctl daemon-reload
  fi

  DEFAULT_MODE="$(sed -n 's/^[[:space:]]*<[[:space:]]*PM_CONFIG[[:space:]]\{1,\}DEFAULT=\([0-9]\{1,\}\).*/\1/p' /etc/nvpmodel.conf 2>/dev/null | head -1)"
  DEFAULT_MODE="${DEFAULT_MODE:-1}"
  echo "--> Resetting nvpmodel to SKU default (mode ${DEFAULT_MODE})..."
  sudocmd nvpmodel -m "${DEFAULT_MODE}" >/dev/null 2>&1 || true

  echo "--> Restoring graphical.target (re-enabling desktop GUI)..."
  sudocmd systemctl set-default graphical.target
  for dm in gdm3 gdm lightdm; do
    if [[ -f "/lib/systemd/system/${dm}.service" ]] || \
       [[ -f "/usr/lib/systemd/system/${dm}.service" ]]; then
      sudocmd systemctl enable "${dm}" 2>/dev/null || true
    fi
  done

  SWAP_FILE="/swapfile"
  SWAP_ACTIVE="$(swapon --show --noheadings 2>/dev/null || true)"
  if grep -q "^${SWAP_FILE}" <<<"${SWAP_ACTIVE}"; then
    echo "--> Deactivating ${SWAP_FILE}..."
    sudocmd swapoff "${SWAP_FILE}"
  fi
  if [[ -f "${SWAP_FILE}" ]]; then
    echo "--> Removing ${SWAP_FILE} (8 GB)..."
    sudocmd rm -f "${SWAP_FILE}"
  fi
  if grep -q "^${SWAP_FILE}" /etc/fstab 2>/dev/null; then
    echo "--> Removing ${SWAP_FILE} from /etc/fstab..."
    FSTAB_TMP="$(mktemp /tmp/fstab.XXXXXX)"
    grep -v "^${SWAP_FILE}" /etc/fstab > "${FSTAB_TMP}"
    sudocmd cp "${FSTAB_TMP}" /etc/fstab
    rm -f "${FSTAB_TMP}"
  fi

  rm -f "${STATE_DIR}/01_prep"
  echo "    Phase 1 environment prep reverted."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Optional: full wipe – remove the entire repo clone
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${FULL_WIPE}" == "true" ]]; then
  echo
  echo "── Full wipe: removing ${REPO_ROOT} ─────────────────────────────────────"
  read -rp "Type 'yes' to confirm: " CONFIRM
  if [[ "${CONFIRM}" == "yes" ]]; then
    cd "${HOME}"
    rm -rf "${REPO_ROOT}"
    echo "    ${REPO_ROOT} removed."
  else
    echo "    Skipped (confirmation not given)."
  fi
else
  if [[ -d "${STATE_DIR}" ]] && [[ -z "${STAGE_FILTER}" ]] && [[ -z "${PHASE_FILTER}" ]]; then
    echo "--> Removing all .setup-state markers..."
    rm -rf "${STATE_DIR}"
  fi
fi

echo
echo "╔════════════════════════════════════════════════════╗"
echo "║  Cleanup complete.                                ║"
echo "╚════════════════════════════════════════════════════╝"
